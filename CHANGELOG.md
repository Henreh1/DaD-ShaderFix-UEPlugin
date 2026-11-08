# Changelog

## 0.2.1 (unreleased)

- Fixed a cook startup error when an Unreal project file contains a trailing
  comma. The cooker now accepts the descriptor and leaves the original project
  file untouched.

## 0.2.0

- Added **Arena map** mode and a **Cook as an arena** option. Arena cooks keep
  property tags and apply the shader corrections.
- The cooker now reuses one working copy per project and syncs changed files
  before each cook. The first cook still needs to make a copy.
- Fixed the text alignment on the **Cook Mod**, **Cancel**, and
  **Open output folder** buttons.
- Fixed the in-editor console log getting stuck at sandbox cleanup. It now
  follows the live UAT log and shows shader progress when UAT is quiet.
- Added **Jobs remaining now** alongside completed shader jobs and batches.
  When available, it counts queued and running jobs and can rise as Unreal
  discovers more work.
- The elapsed timer updates independently of the log and stops when the cook
  ends.
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
