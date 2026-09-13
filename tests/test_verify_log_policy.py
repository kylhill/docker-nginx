"""Offline regression tests exercising the real Bash verification policy."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXCEPTION = (
    "2026/09/13 09:47:54 [emerg] 123#456: "
    "io_setup() failed (38: Function not implemented)"
)
NORMAL = "2026/09/13 09:47:54 [notice] 123#456: start worker processes"
MOCKS = r"""
set -Eeuo pipefail
exec 3>&2
docker() {
    printf 'DOCKER:%s\n' "$*" >&3
    case "$*" in
        "image inspect --format {{.Architecture}} test-image")
            printf '%s\n' "$MOCK_IMAGE_ARCH"
            return "$MOCK_INSPECT_STATUS" ;;
        "info --format {{.Architecture}}")
            printf '%s\n' "$MOCK_DAEMON_ARCH"
            return "$MOCK_INFO_STATUS" ;;
        "logs test-container")
            printf '%s' "$MOCK_LOGS"
            for ((i = 0; i < MOCK_LARGE_LINES; i++)); do
                printf '\n[notice] padding padding padding padding padding padding'
            done
            printf '%s' "$MOCK_LOG_STDERR" >&2
            printf 'LOG_COMPLETE\n' >&3
            return "$MOCK_LOG_STATUS" ;;
        "exec test-container sh "*)
            if [ "$MOCK_RUN_INNER" = 1 ]; then
                shift 2
                [ "$1" = sh ] && [ "$#" = 3 ] || return 98
                local script="${3//\/tmp\//$MOCK_LOCAL_PREFIX}"
                command sh "$2" "$MOCK_INNER_PRELUDE
$script"
            else
                printf '%s' "$MOCK_LOGS"
                return "$MOCK_EXEC_STATUS"
            fi ;;
        *) printf 'UNEXPECTED_DOCKER\n' >&3; return 99 ;;
    esac
}
source scripts/verify-log-policy.sh
"""
INNER_PRELUDE = r"""
cat() { while IFS= read -r line; do :; done; }
nginx() {
    case " $* " in
        *" -s quit "*) printf 'NGINX_QUIT\n'; return 0 ;;
        *) printf 'NGINX_START\n'; return "$MOCK_START_STATUS" ;;
    esac
}
"""


class LogPolicyTests(unittest.TestCase):
    def shell(self, script, **inputs):
        # A clean environment prevents caller policy overrides/exported functions.
        env = {
            "PATH": os.defpath,
            "LC_ALL": "C",
            "IMAGE": "test-image",
            "MOCK_IMAGE_ARCH": "amd64",
            "MOCK_DAEMON_ARCH": "arm64",
            "MOCK_INSPECT_STATUS": "0",
            "MOCK_INFO_STATUS": "0",
            "MOCK_LOG_STATUS": "0",
            "MOCK_EXEC_STATUS": "0",
            "MOCK_LOGS": EXCEPTION,
            "MOCK_LOG_STDERR": "",
            "MOCK_LARGE_LINES": "0",
            "MOCK_RUN_INNER": "0",
        }
        env.update({key: str(value) for key, value in inputs.items()})
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-c", script],
            cwd=ROOT, env=env, capture_output=True, timeout=15,
        )
        # Decode explicitly: universal-newline mode would erase adversarial CRs.
        result.stdout = result.stdout.decode()
        result.stderr = result.stderr.decode()
        self.assertNotIn("UNEXPECTED_DOCKER", result.stderr)
        return result

    def policy(self, **inputs):
        return self.shell(
            MOCKS + "\nconfigure_log_policy\ncheck_container_logs test-container",
            **inputs,
        )

    def assert_result(self, result, status, output=EXCEPTION):
        self.assertEqual(result.returncode, status, result.stderr)
        self.assertEqual(result.stdout, output + "\n")

    def test_default_and_explicit_zero_are_strict_without_arch_queries(self):
        for flag in (None, "0"):
            with self.subTest(flag=flag):
                inputs = {} if flag is None else {"ALLOW_EMULATED_AIO_ENOSYS": flag}
                result = self.policy(**inputs)
                self.assert_result(result, 1)
                self.assertNotIn("DOCKER:image", result.stderr)
                self.assertNotIn("DOCKER:info", result.stderr)

    def test_opt_in_native_architectures_and_aliases_remain_strict(self):
        for image, daemon in (
            ("amd64", "amd64"), ("amd64", "x86_64"),
            ("arm64", "arm64"), ("arm64", "aarch64"),
        ):
            with self.subTest(image=image, daemon=daemon):
                result = self.policy(
                    ALLOW_EMULATED_AIO_ENOSYS=1,
                    MOCK_IMAGE_ARCH=image, MOCK_DAEMON_ARCH=daemon,
                )
                self.assert_result(result, 1)
                self.assertIn("Native", result.stderr)
                self.assertIn("log checks remain strict", result.stderr)

    def test_exact_exception_only_for_cross_architectures_and_aliases(self):
        for image, daemon in (
            ("amd64", "arm64"), ("amd64", "aarch64"),
            ("arm64", "amd64"), ("arm64", "x86_64"),
        ):
            with self.subTest(image=image, daemon=daemon):
                output = "\n".join((NORMAL, EXCEPTION, EXCEPTION, NORMAL))
                result = self.policy(
                    ALLOW_EMULATED_AIO_ENOSYS=1, MOCK_LOGS=output,
                    MOCK_IMAGE_ARCH=image, MOCK_DAEMON_ARCH=daemon,
                )
                self.assert_result(result, 0, output)
                self.assertIn("WARNING:", result.stderr)
                self.assertIn("emulated AIO coverage is reduced", result.stderr)
                self.assertIn("Original output is retained", result.stderr)
                self.assertEqual(result.stderr.count("DOCKER:image inspect"), 1)
                self.assertEqual(result.stderr.count("DOCKER:info"), 1)

    def test_normal_and_empty_logs(self):
        for flag in ("0", "1"):
            for output in ("", NORMAL, "[warn] low resources"):
                with self.subTest(flag=flag, output=output):
                    self.assert_result(
                        self.policy(ALLOW_EMULATED_AIO_ENOSYS=flag, MOCK_LOGS=output),
                        0, output,
                    )

    def test_other_errors_and_near_matches_are_not_exempted(self):
        invalid = [
            *(EXCEPTION.replace("[emerg]", f"[{level}]")
              for level in ("error", "alert", "crit", "EMERG")),
            EXCEPTION.replace("38:", "22:"),
            EXCEPTION.replace("io_setup()", "io_submit()"),
            EXCEPTION.replace("Function not implemented", "Permission denied"),
            EXCEPTION + " suffix", EXCEPTION + "\r", EXCEPTION + " ",
            EXCEPTION + "\t",
            EXCEPTION.removeprefix("2026/09/13 09:47:54 "),
            EXCEPTION.replace("2026/09/13 ", ""),
            EXCEPTION.replace("2026/09/13", "2026/9/13"),
            EXCEPTION.replace("09:47:54", "9:47:54"),
            EXCEPTION.replace("09:47:54", "09:47"),
            EXCEPTION.replace("2026/09/13", "2026-09-13"),
            EXCEPTION.replace("123#456: ", ""),
            EXCEPTION.replace("123#456", "123"),
            EXCEPTION.replace("123#456", "pid#456"),
            EXCEPTION.replace("123#456", "123#tid"),
            "prefix " + EXCEPTION,
            "ERROR: unrelated failure", "FATAL: unrelated failure",
        ]
        for line in invalid:
            with self.subTest(line=line):
                output = EXCEPTION + "\n" + line
                self.assert_result(
                    self.policy(ALLOW_EMULATED_AIO_ENOSYS=1, MOCK_LOGS=output),
                    1, output,
                )

    def test_malformed_non_error_prefixes_are_not_filtered(self):
        for line in (
            "io_setup() failed (38: Function not implemented)",
            EXCEPTION.replace("[emerg] ", ""),
            EXCEPTION.replace("[emerg]", "[notice]"),
            EXCEPTION.replace("[emerg]", "emerg"),
        ):
            with self.subTest(line=line):
                self.assert_result(
                    self.policy(ALLOW_EMULATED_AIO_ENOSYS=1, MOCK_LOGS=line),
                    0, line,
                )
                # The real filter must retain the line even if the default error
                # detector ignores it. A literal custom detector observes that.
                self.assert_result(
                    self.policy(
                        ALLOW_EMULATED_AIO_ENOSYS=1, MOCK_LOGS=line,
                        LOG_ERROR_REGEX="io_setup",
                    ),
                    1, line,
                )

    def test_unknown_architectures_are_strict_with_diagnostics(self):
        for image, daemon in (
            ("amd64", "unknown"), ("unknown", "arm64"),
            ("", "arm64"), ("amd64", ""), ("riscv64", "arm64"),
            ("amd64", "riscv64"), ("x86_64", "arm64"),
            ("aarch64", "amd64"),
        ):
            with self.subTest(image=image, daemon=daemon):
                result = self.policy(
                    ALLOW_EMULATED_AIO_ENOSYS=1,
                    MOCK_IMAGE_ARCH=image, MOCK_DAEMON_ARCH=daemon,
                )
                self.assert_result(result, 1)
                self.assertIn(f"'{image}'/'{daemon}'", result.stderr)
                self.assertIn("Unknown image/daemon architecture", result.stderr)
                self.assertIn("strict (no exception)", result.stderr)

    def test_failed_architecture_queries_abort_before_logs(self):
        for variable, diagnostic in (
            ("MOCK_INSPECT_STATUS", "Could not inspect image architecture"),
            ("MOCK_INFO_STATUS", "Could not read Docker daemon architecture"),
        ):
            with self.subTest(variable=variable):
                result = self.policy(
                    ALLOW_EMULATED_AIO_ENOSYS=1, **{variable: 23},
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assertIn("refusing log exception", result.stderr)
                self.assertNotIn("DOCKER:logs", result.stderr)
                if variable == "MOCK_INSPECT_STATUS":
                    self.assertNotIn("DOCKER:info", result.stderr)

    def test_configuration_resets_previous_eligibility(self):
        result = self.shell(
            MOCKS + """
configure_log_policy
[ "$EMULATED_AIO_ENOSYS_ELIGIBLE" = 1 ]
MOCK_DAEMON_ARCH=amd64
configure_log_policy
check_container_logs test-container
""",
            ALLOW_EMULATED_AIO_ENOSYS=1,
        )
        self.assert_result(result, 1)

    def test_log_reads_are_complete_once_and_preserve_failure_status(self):
        for status in (0, 7, 42, 141):
            with self.subTest(status=status):
                result = self.policy(
                    ALLOW_EMULATED_AIO_ENOSYS=1, MOCK_LOG_STATUS=status,
                    MOCK_LOGS=EXCEPTION, MOCK_LOG_STDERR="\nlast diagnostic",
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(result.stderr.count("DOCKER:logs test-container"), 1)
                self.assertEqual(result.stderr.count("LOG_COMPLETE"), 1)
                if status:
                    self.assertEqual(result.stdout, "")
                    self.assertIn(EXCEPTION + "\nlast diagnostic\n", result.stderr)
                    self.assertIn("Could not read container logs", result.stderr)
                else:
                    self.assertEqual(result.stdout, EXCEPTION + "\nlast diagnostic\n")

    def test_large_error_logs_do_not_hide_errors_through_sigpipe(self):
        for flag in (0, 1):
            with self.subTest(flag=flag):
                result = self.policy(
                    ALLOW_EMULATED_AIO_ENOSYS=flag,
                    MOCK_LOGS="[error] first line", MOCK_LARGE_LINES=8192,
                    MOCK_LOG_STDERR="\nlast diagnostic",
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertTrue(result.stdout.startswith("[error] first line\n"))
                self.assertEqual(result.stdout.count("[notice] padding"), 8192)
                self.assertTrue(result.stdout.endswith("\nlast diagnostic\n"))
                self.assertEqual(result.stderr.count("DOCKER:logs test-container"), 1)
                self.assertEqual(result.stderr.count("LOG_COMPLETE"), 1)
                self.assertIn("nginx output matched error regex", result.stderr)

    def test_invalid_flags_abort_entry_scripts_before_any_resources(self):
        guard = r"""
set -Eeuo pipefail
exec 3>&2
blocked() { printf 'RESOURCE:%s\n' "$*" >&3; exit 97; }
docker() { blocked docker "$@"; }
mkdir() { blocked mkdir "$@"; }
mktemp() { blocked mktemp "$@"; }
cp() { blocked cp "$@"; }
rm() { blocked rm "$@"; }
chmod() { blocked chmod "$@"; }
openssl() { blocked openssl "$@"; }
sleep() { blocked sleep "$@"; }
export -f blocked docker mkdir mktemp cp rm chmod openssl sleep
bash "$MOCK_ENTRY"
"""
        for entry in ("verify-image.sh", "verify-integration.sh"):
            for flag in ("", "2", "-1", "true", "yes", "01", " 1", "1 ", "1\n"):
                with self.subTest(entry=entry, flag=flag):
                    result = self.shell(
                        guard, MOCK_ENTRY=f"scripts/{entry}",
                        ALLOW_EMULATED_AIO_ENOSYS=flag, SKIP_BUILD=0,
                    )
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("ALLOW_EMULATED_AIO_ENOSYS must be 0 or 1.", result.stderr)
                    self.assertNotIn("RESOURCE:", result.stderr)
                    self.assertNotIn("Building ", result.stdout)

    def lua(self, **inputs):
        source = (ROOT / "scripts/verify-integration.sh").read_text()
        start = source.index("\ncheck_lua_modules() {") + 1
        end = source.index("\ntest_contract() {", start)
        return self.shell(
            MOCKS + "\n" + source[start:end]
            + "\nconfigure_log_policy\ncheck_lua_modules test-container",
            **inputs,
        )

    def test_lua_uses_real_policy_and_preserves_exec_failures(self):
        for flag, output, exec_status, expected in (
            (0, EXCEPTION, 0, 1), (1, EXCEPTION, 0, 0),
            (1, NORMAL, 0, 0), (1, "[error] Lua load failed", 0, 1),
            (1, EXCEPTION + " ", 0, 1),
            (1, EXCEPTION, 19, 19), (1, NORMAL, 43, 43),
        ):
            with self.subTest(flag=flag, output=output, exec_status=exec_status):
                result = self.lua(
                    ALLOW_EMULATED_AIO_ENOSYS=flag, MOCK_LOGS=output,
                    MOCK_EXEC_STATUS=exec_status,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stderr.count("DOCKER:exec test-container"), 1)
                if exec_status:
                    self.assertEqual(result.stdout, "")
                    self.assertIn(output + "\n", result.stderr)
                else:
                    self.assertEqual(result.stdout, output + "\n")

    def test_lua_inner_sh_stops_on_startup_failure_before_successful_quit(self):
        # Only redirect the actual script's /tmp paths; execute its sh flags and
        # commands unchanged, with cat/nginx functions instead of real binaries.
        with tempfile.TemporaryDirectory(prefix="verify-log-policy-") as directory:
            prefix = directory + "/"
            for status in (0, 27):
                with self.subTest(start_status=status):
                    result = self.lua(
                        MOCK_RUN_INNER=1, MOCK_LOCAL_PREFIX=prefix,
                        MOCK_INNER_PRELUDE=INNER_PRELUDE, MOCK_START_STATUS=status,
                    )
                    self.assertEqual(result.returncode, status, result.stderr)
                    output = result.stderr if status else result.stdout
                    # The Docker trace also contains the shell source, so test
                    # actual emitted lines rather than occurrences in the trace.
                    self.assertIn("\nNGINX_START\n", "\n" + output)
                    self.assertEqual("\nNGINX_QUIT\n" in "\n" + output, status == 0)


if __name__ == "__main__":
    unittest.main()
