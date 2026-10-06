"""Local integration tests for the shared Bash submodule helpers."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(os.environ.get(
    "GIT_COMMON_SCRIPT",
    str(Path(__file__).with_name("odoo-git-common.sh")),
))


class GitSubmoduleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="git-submodule-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = os.environ.copy()
        self.env.update({
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        })
        self.repo = self.init_repo("parent")
        self.initial = self.commit_file(self.repo, "parent.txt", "initial\n")
        self.remote = self.init_repo("module-remote")
        self.module_old = self.commit_file(self.remote, "module.txt", "old\n")

    def command(self, argv, cwd, check=True):
        result = subprocess.run(
            argv, cwd=cwd, env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        )
        if check and result.returncode:
            self.fail(f"{argv!r} failed ({result.returncode})\n"
                      f"{result.stdout}\n{result.stderr}")
        return result

    def git(self, repo, *args, check=True):
        return self.command(["git", *args], repo, check=check)

    def init_repo(self, name):
        repo = self.root / name
        repo.mkdir()
        self.git(repo, "init", "--initial-branch=main")
        self.git(repo, "config", "user.name", "Local Test")
        self.git(repo, "config", "user.email", "local-test@example.invalid")
        return repo

    def head(self, repo):
        return self.git(repo, "rev-parse", "HEAD").stdout.strip()

    def commit_file(self, repo, filename, content):
        (repo / filename).write_text(content, encoding="utf-8")
        self.git(repo, "add", filename)
        self.git(repo, "commit", "-m", "fixture change")
        return self.head(repo)

    def add_module(self):
        self.git(self.repo, "submodule", "add", str(self.remote), "module")
        self.git(self.repo, "commit", "-m", "add module")
        return self.head(self.repo)

    def clone_parent(self):
        clone = self.root / "clone"
        self.git(self.root, "clone", str(self.repo), str(clone))
        self.git(clone, "config", "user.name", "Local Test")
        self.git(clone, "config", "user.email", "local-test@example.invalid")
        return clone

    def helper(self, name, *args, repo=None, check=True):
        self.assertTrue(SCRIPT.is_file(), f"Helper missing: {SCRIPT}")
        return self.command([
            "bash", "-c",
            'source "$1" || exit $?; shift; '
            'run_repo_git() { git "$@"; }; "$@"',
            "submodule-tests", str(SCRIPT), name, *args,
        ], repo or self.repo, check=check)

    def test_repo_without_submodules(self):
        self.helper("sync_repo_submodules")
        newer = self.commit_file(self.repo, "parent.txt", "new\n")
        self.assertNotEqual(newer, self.initial)
        self.helper("restore_repo_commit", self.initial)
        self.assertEqual(self.head(self.repo), self.initial)
        self.assertEqual((self.repo / "parent.txt").read_text(), "initial\n")

    def test_initialization_uses_pin_when_remote_branch_advances(self):
        self.add_module()
        advanced = self.commit_file(self.remote, "module.txt", "advanced\n")
        self.assertNotEqual(advanced, self.module_old)
        clone = self.clone_parent()
        self.helper("sync_repo_submodules", repo=clone)
        self.assertEqual(self.head(clone / "module"), self.module_old)

    def test_update_pin_and_restore_old_pin(self):
        old_parent = self.add_module()
        new_module = self.commit_file(self.remote, "module.txt", "new\n")
        self.git(self.repo / "module", "fetch", "origin")
        self.git(self.repo / "module", "checkout", new_module)
        self.git(self.repo, "add", "module")
        self.git(self.repo, "commit", "-m", "update pin")
        new_parent = self.head(self.repo)
        clone = self.clone_parent()
        self.git(clone, "reset", "--hard", old_parent)
        self.helper("sync_repo_submodules", repo=clone)
        self.assertEqual(self.head(clone / "module"), self.module_old)
        self.git(clone, "reset", "--hard", new_parent)
        self.helper("sync_repo_submodules", repo=clone)
        self.assertEqual(self.head(clone / "module"), new_module)
        self.helper("restore_repo_commit", old_parent, repo=clone)
        self.assertEqual(self.head(clone), old_parent)
        self.assertEqual(self.head(clone / "module"), self.module_old)

    def test_restore_before_first_addition_removes_module_worktree(self):
        self.add_module()
        self.helper("restore_repo_commit", self.initial)
        self.assertEqual(self.head(self.repo), self.initial)
        module = self.repo / "module"
        self.assertTrue(not module.exists() or not any(module.iterdir()))
        self.assertFalse((self.repo / ".gitmodules").exists())

    def test_broken_url_propagates_failure(self):
        self.add_module()
        self.git(self.repo, "config", "-f", ".gitmodules", "submodule.module.url",
                 str(self.root / "missing-remote"))
        self.git(self.repo, "add", ".gitmodules")
        self.git(self.repo, "commit", "-m", "broken URL")
        clone = self.clone_parent()
        result = self.helper("sync_repo_submodules", repo=clone, check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_pinned_commit_propagates_failure(self):
        self.add_module()
        missing = "1" * 40
        self.git(self.repo, "update-index", "--cacheinfo", f"160000,{missing},module")
        self.git(self.repo, "commit", "-m", "missing pin")
        clone = self.clone_parent()
        result = self.helper("sync_repo_submodules", repo=clone, check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_restore_commit_propagates_failure(self):
        result = self.helper("restore_repo_commit", "1" * 40, check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(self.repo), self.initial)

    def test_dirty_module_prevents_restore_and_preserves_changes(self):
        added_parent = self.add_module()
        dirty_file = self.repo / "module" / "module.txt"
        dirty_file.write_text("local changes\n", encoding="utf-8")
        result = self.helper("restore_repo_commit", self.initial, check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(self.repo), added_parent)
        self.assertEqual(dirty_file.read_text(), "local changes\n")
        self.assertEqual(self.head(self.repo / "module"), self.module_old)

    def test_clean_guard_rejects_tracked_and_untracked_changes(self):
        self.add_module()
        self.helper("check_repo_submodules_clean")
        module_file = self.repo / "module" / "module.txt"
        module_file.write_text("local changes\n", encoding="utf-8")
        result = self.helper("check_repo_submodules_clean", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(module_file.read_text(), "local changes\n")
        module_file.write_text("old\n", encoding="utf-8")
        untracked = self.repo / "module" / "local.txt"
        untracked.write_text("untracked\n", encoding="utf-8")
        result = self.helper("check_repo_submodules_clean", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(untracked.read_text(), "untracked\n")


if __name__ == "__main__":
    unittest.main()
