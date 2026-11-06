using UnrealBuildTool;

public class LimelightShaderCooker : ModuleRules
{
    public LimelightShaderCooker(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PrivateDependencyModuleNames.AddRange(new[]
        {
            "Core", "CoreUObject", "Engine", "UnrealEd", "Slate", "SlateCore",
            "ToolMenus", "Projects", "DesktopPlatform", "Json", "InputCore", "PropertyEditor", "AssetRegistry"
        });
    }
}
