# Limelight Shader Cooker

First public release: **0.1.0**.

I use this to cook lit materials for Dead as Disco CL-35029 with the
Epic UE 5.7.4 editor (CL-51494982). The correction keeps the original material's
lighting, opacity graph and DBuffer decal response.

> [!IMPORTANT]
> If you do not already you will need to install Visual Studio's **Game development with C++** tools

I've tested these in-game on 6 November 2026:

| Mod | Renderer | What worked |
| --- | --- | --- |
| Chun-Li | DX12 / SM6 | DiveBar load with DBuffer response enabled on ten opaque/masked parents and the original lit translucent eye material. |
| Wallace | DX12 / SM6 and DX11 / SM5 | Selected-label cook, all nine character packages in chunk 1990, and the character loading in the DiveBar on both renderers. |

The game logs confirm the renderers used for the Wallace tests, and the installed
files match the successful cook. The DX11 test covers Wallace's opaque material;
translucent materials still need a separate DX11 test. 

1. Close the editor and put the complete `LimelightShaderCooker` folder in your
   project's `Plugins` folder. Use the prebuilt download if you don't build C++.
2. Reopen the project. Open **Tools > Cook for Dead as Disco**.
3. Select **Data asset**, **Content folder**, or **Cook All**, choose an output
   folder, then click **Cook Mod**. Data asset mode uses Unreal's asset picker.
4. Use **Open output folder**. The `Build` directory contains the usual packaged
   `.pak`, `.utoc` and `.ucas` files. Use the matching sets for your mod's assigned
   chunks, following your usual mod installation workflow.

The output may also contain engine/plugin content and duplicate chunks from
overlapping labels.

For a C++ project, I reuse its Win64 Development game binaries when the mod kit
includes them. If they are missing, the cooker builds that target before making
the cook copy. This needs Visual Studio's **Game development with C++** tools and
a Windows SDK. There is no separate packaging step. Compiler errors are saved
to `NativeBuild.txt`; they stop the run before shader compilation starts.

Your existing packaging rules and chunk labels still apply. Selecting an asset
adds that package and its referenced dependencies; selecting a folder adds all
packages under it. Selecting a Primary Asset Label requests its explicit,
directory and collection bundle contents, including nested labels. Asset and
folder modes turn off the project's Cook All flag in the temporary copy.
Cook All requests the entire project, including unused content, while still
respecting never-cook rules. These modes do not override other
always-cook folders or force all assets into a new chunk. Check the chunks you
normally distribute.

I save the project before refreshing one separate working copy per project.
Unchanged files are reused; changed and added files are copied, and files removed
from the source are removed from the working copy. The copy keeps assets available
for dependency resolution; it does not select every asset for cooking. Once the
status says it is cooking, you can keep editing the source project. The cooking
status cycles its dots while the cook process is running.
Normal editor previews and normal packaging keep using their existing compiler
and cache. The copy
uses a private shader cache and NullRHI, so corrected shaders stay out of the
stock renderer and shared cache.

Working copies live under `LimelightSC/Projects` in the Windows temporary folder.
The cooker checks its ownership marker and holds a per-project lock before
refreshing or cleaning a copy. It refuses linked workspace paths. Old cooked,
staged and intermediate data is cleared before reuse and after a successful cook.
The private DDC is reused separately, with Unreal's cleanup of entries unused for
14 days enabled. It can still be large for large projects. Working copies from
older versions under `LimelightSC/Runs` are not automatically adopted or deleted.

This version corrects the known `TranslucentBasePass` and `OpaqueBasePass`
layouts. The opaque correction keeps the material's existing DBuffer decal
response. Unknown layouts stop the cook instead of producing a
guessed shader. The cooker retains stock shader logic while aligning the two
known resource layouts.

`Console.txt`, `UATLogs` and `Result.json` are saved with each run. Enable **Save
shader debug files** if you need compiler diagnostics. Normal cooks discard
completed shader batch captures; debug-enabled cooks retain corrected batches,
and failed batches are retained. Worker logs, cook metadata and requested debug
files are moved into that run's output folder before scratch cleanup. An
interrupted cook's remaining diagnostics are recovered into the next run's
`PreviousCookDiagnostics` folder. Packaged outputs are kept per run.
`Result.json` includes the reusable cook project path, copied/reused file counts,
corrected job count, cleanup warnings and packaged file hashes.
Material compilation warnings are listed there even when UAT returns success.
The cook report lists the cooked `/Game` packages and checks that selected
packages were included. A successful engine-only build is not accepted as a mod.
The source materials and configuration are left as authored. A missing native
build creates the project's usual generated binaries and intermediate files.
The temporary copy adds its own cache and shader-worker configuration.

Also yes, I know it says "Bear with me". It was 4am, its staying like that!

## Building

Run `Tools/Build-Plugin.ps1` with an installed .NET 9 SDK and the supported engine.
Pass your engine installation folder with `-EngineRoot`; its location is not
fixed. The plugin itself detects the engine running the editor.
The build script builds the .NET 8 worker and packages the editor plugin with
UAT. Using the prebuilt plugin requires no separate Python installation or source-engine build;
the cooker uses the engine's bundled Python and .NET runtime.

<a href="https://brainmade.org/">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://brainmade.org/white-logo.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://brainmade.org/black-logo.svg">
  <img alt="brainmade" src="https://brainmade.org/white-logo.svg">
</picture>
</a>
