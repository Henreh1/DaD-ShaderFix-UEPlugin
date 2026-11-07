# Changelog

## 0.2.0 (unreleased)

- The cooker now reuses one working copy per project and syncs changed files
  before each cook. The first cook still needs to make a copy.
- The plugin window follows the live UAT log, shows shader progress when UAT
  is quiet, and keeps an elapsed timer that stops when the cook ends.
- The cook status shows completed shader jobs and batches and, when available,
  how many shader jobs are still queued or running. That count can rise as
  Unreal discovers more work.
- If a shader batch goes 15 minutes without a result, or Unreal reports that a
  worker exited without returning one, the cooker saves diagnostics and retries
  once with lower parallelism. A second stall stops the cook and leaves logs
  from both attempts.
- Added the Apache 2.0 license.

## 0.1.0

- First public release for Dead as Disco CL-35029 and Epic UE 5.7.4 on Windows.
- Cooks lit opaque, masked, and translucent materials with the game's shader
  layouts so mods can keep their lighting, opacity, and DBuffer decal response.
- Supports cooking a data asset, a content folder, or the whole project.
