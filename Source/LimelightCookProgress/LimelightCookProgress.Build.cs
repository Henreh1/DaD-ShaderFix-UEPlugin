using UnrealBuildTool;

public class LimelightCookProgress : ModuleRules
{
    public LimelightCookProgress(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PrivateDependencyModuleNames.AddRange(new[] { "Core", "CoreUObject", "Engine", "RenderCore", "RHI", "Json" });
    }
}
