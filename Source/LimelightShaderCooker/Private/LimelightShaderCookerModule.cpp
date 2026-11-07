#include "Containers/Queue.h"
#include "CookLogTail.h"
#include "AssetRegistry/AssetData.h"
#include "AssetRegistry/AssetRegistryModule.h"
#include "Containers/Ticker.h"
#include "DesktopPlatformModule.h"
#include "Dom/JsonObject.h"
#include "Engine/DataAsset.h"
#include "Engine/PrimaryAssetLabel.h"
#include "Engine/World.h"
#include "FileHelpers.h"
#include "Framework/Application/SlateApplication.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformProcess.h"
#include "HAL/PlatformTime.h"
#include "IDesktopPlatform.h"
#include "Interfaces/IPluginManager.h"
#include "Misc/App.h"
#include "Misc/ConfigCacheIni.h"
#include "Misc/DateTime.h"
#include "Misc/FileHelper.h"
#include "Misc/Guid.h"
#include "Misc/MonitoredProcess.h"
#include "Misc/PackageName.h"
#include "Misc/Paths.h"
#include "Modules/ModuleManager.h"
#include "PropertyCustomizationHelpers.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "Styling/AppStyle.h"
#include "ToolMenus.h"
#include "Widgets/Docking/SDockTab.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Input/SCheckBox.h"
#include "Widgets/Input/SComboBox.h"
#include "Widgets/Input/SEditableTextBox.h"
#include "Widgets/Input/SMultiLineEditableTextBox.h"
#include "Widgets/Layout/SBorder.h"
#include "Widgets/Layout/SBox.h"
#include "Widgets/Layout/SScrollBox.h"
#include "Widgets/Text/STextBlock.h"

#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"
#include "Misc/ScopeExit.h"
#endif

DEFINE_LOG_CATEGORY_STATIC(LogLimelightShaderCooker, Log, All);
#define LOCTEXT_NAMESPACE "LimelightShaderCooker"

namespace
{
const FName CookerTab(TEXT("LimelightShaderCooker"));
constexpr int32 PendingExit = MIN_int32;
const TCHAR* SettingsSection = TEXT("LimelightShaderCooker");
constexpr TCHAR StatusPrefix[] = TEXT("LIMELIGHT_STATUS ");

FString FullPath(const FString& Path)
{
    FString Result = FPaths::ConvertRelativePathToFull(Path);
    FPaths::NormalizeFilename(Result);
    return Result;
}

FString Quote(const FString& Value)
{
    return FString::Printf(TEXT("\"%s\""), *Value);
}

bool ResolveCookPackages(const FString& AssetPath, TArray<FString>& Packages, FString& Error)
{
    IAssetRegistry& Registry = FModuleManager::LoadModuleChecked<FAssetRegistryModule>(TEXT("AssetRegistry")).Get();
    Registry.WaitForCompletion();
    TArray<FSoftObjectPath> Pending{FSoftObjectPath(AssetPath)};
    TSet<FString> Visited;
    while (!Pending.IsEmpty())
    {
        const FSoftObjectPath Path = Pending.Pop(EAllowShrinking::No);
        const FString Package = Path.GetLongPackageName();
        if (Visited.Contains(Package)) continue;
        Visited.Add(Package);
        const FAssetData Data = Registry.GetAssetByObjectPath(Path);
        if (Data.IsInstanceOf(UPrimaryAssetLabel::StaticClass()))
        {
            UPrimaryAssetLabel* Label = Cast<UPrimaryAssetLabel>(Data.GetAsset());
            if (!Label) { Error = TEXT("Could not load the selected asset label."); return false; }
            // I request the label's contents because editor-only labels are stripped from a cook.
            Label->UpdateAssetBundleData();
            const FAssetData Current(Label);
            if (Current.TaggedAssetBundles)
                for (const FAssetBundleEntry& Bundle : Current.TaggedAssetBundles->Bundles)
                    for (const FTopLevelAssetPath& Entry : Bundle.AssetPaths)
                        Pending.Add(FSoftObjectPath(Entry));
            if (!Label->bIsRuntimeLabel) continue;
        }
        if (!Package.StartsWith(TEXT("/Game/")) || !FPackageName::IsValidLongPackageName(Package))
        {
            Error = FString::Printf(TEXT("A selected label references a root outside /Game content: %s"), *Package);
            return false;
        }
        Packages.AddUnique(Package);
    }
    Packages.Sort();
    if (Packages.IsEmpty()) { Error = TEXT("The selected label contains no assets to cook."); return false; }
    return true;
}

struct FProcessState
{
    TQueue<FString, EQueueMode::Mpsc> Lines;
    TAtomic<int32> ExitCode{PendingExit};
};

class FCookSession
{
public:
    ~FCookSession() { Stop(); }

    bool Start(const FString& Mode, const FString& AssetPath, const FString& Folder, const FString& OutputRoot, bool bDebug, bool bArenaCook)
    {
        if (bRunning) return false;
        const TSharedPtr<IPlugin> Plugin = IPluginManager::Get().FindPlugin(TEXT("LimelightShaderCooker"));
        const FString Project = FullPath(FPaths::GetProjectFilePath());
        FString ContentFolder = Folder.TrimStartAndEnd();
        ContentFolder.ReplaceInline(TEXT("\\"), TEXT("/"));
        while (ContentFolder.EndsWith(TEXT("/"))) ContentFolder.LeftChopInline(1);
        if (!Plugin || !FPaths::FileExists(Project) || !Project.EndsWith(TEXT(".uproject")))
            return Fail(TEXT("The active project or cooker plugin could not be found."));
        if (Mode == TEXT("Folder") && ContentFolder != TEXT("/Game") && !ContentFolder.StartsWith(TEXT("/Game/")))
            return Fail(TEXT("Choose a folder inside this project's Content directory."));
        TArray<FString> Parts;
        ContentFolder.ParseIntoArray(Parts, TEXT("/"));
        if (Mode == TEXT("Folder") && (Parts.Contains(TEXT("..")) || Parts.Contains(TEXT(".")) || ContentFolder.Contains(TEXT("\""))))
            return Fail(TEXT("Enter a /Game/... folder without dot segments or quotes."));
        const FString DiskFolder = FullPath(FPaths::Combine(FPaths::ProjectContentDir(), ContentFolder == TEXT("/Game") ? FString() : ContentFolder.RightChop(6)));
        if (Mode == TEXT("Folder") && !IFileManager::Get().DirectoryExists(*DiskFolder))
            return Fail(TEXT("The selected content folder does not exist."));
        const FString AssetPackage = FPackageName::ObjectPathToPackageName(AssetPath);
        const bool bAssetSelection = Mode == TEXT("Asset") || Mode == TEXT("Map");
        if (bAssetSelection && (!AssetPackage.StartsWith(TEXT("/Game/")) || !FPackageName::IsValidLongPackageName(AssetPackage)))
            return Fail(TEXT("Select a saved asset or arena map from this project's Content directory."));
        if (OutputRoot.TrimStartAndEnd().IsEmpty() || OutputRoot.Contains(TEXT("\"")) || OutputRoot.Contains(TEXT("\n")))
            return Fail(TEXT("Choose an output folder."));
        const FString Script = FullPath(FPaths::Combine(Plugin->GetBaseDir(), TEXT("Resources/Cooker/Cook-Mod.ps1")));
        if (!FPaths::FileExists(Script)) return Fail(TEXT("The cooker payload is missing. Install the complete plugin folder."));

        // I save before making the cook copy so it uses the assets shown in the editor.
        if (!FEditorFileUtils::SaveDirtyPackages(true, true, true, false, false, false))
            return Fail(TEXT("Cook cancelled because modified assets were not saved."));
        if (bAssetSelection && !FPackageName::DoesPackageExist(AssetPackage))
            return Fail(TEXT("The selected asset or map could not be found on disk after saving."));
        TArray<FString> CookPackages;
        FString SelectionError;
        if (bAssetSelection && !ResolveCookPackages(AssetPath, CookPackages, SelectionError)) return Fail(SelectionError);

        const FString RunId = FDateTime::UtcNow().ToString(TEXT("%Y%m%d-%H%M%S-")) + FGuid::NewGuid().ToString(EGuidFormats::Digits).Left(8);
        const FString RequestFolder = FullPath(FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("ShaderCooker/Requests")));
        LastOutput = FullPath(FPaths::Combine(OutputRoot.TrimStartAndEnd(), RunId));
        if (!IFileManager::Get().MakeDirectory(*RequestFolder, true)) return Fail(TEXT("Could not create the request folder."));
        TSharedRef<FJsonObject> Request = MakeShared<FJsonObject>();
        Request->SetStringField(TEXT("Project"), Project);
        Request->SetStringField(TEXT("Engine"), FullPath(FPaths::RootDir()));
        Request->SetStringField(TEXT("ContentFolder"), ContentFolder);
        Request->SetStringField(TEXT("Mode"), Mode);
        Request->SetStringField(TEXT("AssetPackage"), AssetPackage);
        TArray<TSharedPtr<FJsonValue>> PackageValues;
        for (const FString& Package : CookPackages) PackageValues.Add(MakeShared<FJsonValueString>(Package));
        Request->SetArrayField(TEXT("AssetPackages"), PackageValues);
        Request->SetStringField(TEXT("OutputRoot"), FullPath(OutputRoot.TrimStartAndEnd()));
        Request->SetStringField(TEXT("WorkRoot"), FullPath(FPaths::Combine(FPlatformProcess::UserTempDir(), TEXT("LimelightSC"))));
        Request->SetStringField(TEXT("RunId"), RunId);
        Request->SetBoolField(TEXT("ShaderDebug"), bDebug);
        Request->SetBoolField(TEXT("ArenaCook"), Mode == TEXT("Map") || bArenaCook);
        FString Json;
        FJsonSerializer::Serialize(Request, TJsonWriterFactory<>::Create(&Json));
        const FString RequestPath = FPaths::Combine(RequestFolder, RunId + TEXT(".json"));
        if (!FFileHelper::SaveStringToFile(Json, *RequestPath, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM))
            return Fail(TEXT("Could not write the cook request."));
        const FString PowerShell = FPlatformMisc::GetEnvironmentVariable(TEXT("SystemRoot")) + TEXT("/System32/WindowsPowerShell/v1.0/powershell.exe");
        const FString Args = TEXT("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ") + Quote(Script) + TEXT(" -Request ") + Quote(RequestPath);
        State = MakeShared<FProcessState, ESPMode::ThreadSafe>();
        const TSharedRef<FProcessState, ESPMode::ThreadSafe> SharedState = State.ToSharedRef();
        Process = MakeUnique<FMonitoredProcess>(PowerShell, Args, Plugin->GetBaseDir(), true);
        Process->OnOutput().BindLambda([SharedState](FString Line) { SharedState->Lines.Enqueue(MoveTemp(Line)); });
        Process->OnCompleted().BindLambda([SharedState](int32 Code) { SharedState->ExitCode.Store(Code); });
        Process->OnCanceled().BindLambda([SharedState]() { SharedState->ExitCode.Store(-2); });
        if (!Process->Launch()) { Process.Reset(); return Fail(TEXT("Could not start the cook helper.")); }
        StartedAt = FPlatformTime::Seconds();
        bRunning = true;
        bCooking = false;
        bCancelling = false;
        bError = false;
        Status = TEXT("Checking project and preparing a cook copy...");
        Output.Empty();
        LogTail = FCookLogTail();
        NextLogRead = 0.0;
        ++LogRevision;
        GConfig->SetString(SettingsSection, TEXT("ContentFolder"), *ContentFolder, GEditorPerProjectIni);
        GConfig->SetString(SettingsSection, TEXT("Mode"), *Mode, GEditorPerProjectIni);
        if (bAssetSelection) GConfig->SetString(SettingsSection, Mode == TEXT("Map") ? TEXT("MapPath") : TEXT("AssetPath"), *AssetPath, GEditorPerProjectIni);
        GConfig->SetString(SettingsSection, TEXT("OutputRoot"), *FullPath(OutputRoot.TrimStartAndEnd()), GEditorPerProjectIni);
        GConfig->Flush(false, GEditorPerProjectIni);
        return true;
    }

    void Tick()
    {
        if (!bRunning || !State) return;
        const int32 Code = State->ExitCode.Load();
        const double Now = FPlatformTime::Seconds();
        if (Now >= NextLogRead || Code != PendingExit)
        {
            if (LogTail.Update(LastOutput, Code != PendingExit, Output)) ++LogRevision;
            NextLogRead = Now + 0.25;
        }
        FString Line;
        bool bPipeOutputChanged = false;
        while (State->Lines.Dequeue(Line))
        {
            UE_LOG(LogLimelightShaderCooker, Display, TEXT("%s"), *Line);
            if (!LogTail.HasFile())
            {
                Output += Line + TEXT("\n");
                bPipeOutputChanged = true;
            }
            if (Line.StartsWith(StatusPrefix))
            {
                const FString Message = Line.RightChop(UE_ARRAY_COUNT(StatusPrefix) - 1);
                if (LogTail.IsUatLog())
                {
                    if (!Output.IsEmpty() && !Output.EndsWith(TEXT("\n"))) Output.AppendChar('\n');
                    Output += TEXT("[Cooker] ") + Message + TEXT("\n");
                    bPipeOutputChanged = true;
                }
                if (!bCancelling)
                {
                    Status = Message;
                    const bool bShaderProgress = Status.StartsWith(TEXT("Compiling shaders:"));
                    if (bShaderProgress)
                    {
                        const int32 ElapsedIndex = Status.Find(TEXT(" Elapsed "), ESearchCase::CaseSensitive, ESearchDir::FromEnd);
                        if (ElapsedIndex != INDEX_NONE) Status.LeftInline(ElapsedIndex, EAllowShrinking::No);
                    }
                    bCooking = bShaderProgress || Status.StartsWith(TEXT("Cooking the saved project copy."));
                }
            }
        }
        if (bPipeOutputChanged)
        {
            FCookLogTail::Trim(Output);
            ++LogRevision;
        }
        if (Code == PendingExit) return;
        Process.Reset();
        State.Reset();
        FinishedAt = Now;
        bRunning = false;
        bCooking = false;
        bCancelling = false;
        bError = Code != 0;
        if (Code == -2) Status = TEXT("Cook cancelled. Partial files and diagnostics remain in the output folder.");
        else if (Code != 0) Status = FString::Printf(TEXT("Cook failed (exit %d). Open the output folder and check Console.txt."), Code);
        else
        {
            FString ResultText;
            TSharedPtr<FJsonObject> Result;
            if (FFileHelper::LoadFileToString(ResultText, *FPaths::Combine(LastOutput, TEXT("Result.json"))) &&
                FJsonSerializer::Deserialize(TJsonReaderFactory<>::Create(ResultText), Result) && Result.IsValid())
            {
                bool bSucceeded = false;
                Result->TryGetBoolField(TEXT("Succeeded"), bSucceeded);
                if (bSucceeded)
                {
                    const TArray<TSharedPtr<FJsonValue>>* Warnings = nullptr;
                    const bool bHasWarnings = Result->TryGetArrayField(TEXT("MaterialWarnings"), Warnings) && Warnings && !Warnings->IsEmpty();
                    FString StorageWarning;
                    Result->TryGetStringField(TEXT("StorageWarning"), StorageWarning);
                    Status = !StorageWarning.IsEmpty() ? TEXT("Cook completed, but temporary cleanup failed. Check Result.json before the next cook.") : bHasWarnings ? TEXT("Cook completed with material warnings. Check Result.json before distributing the mod.") : TEXT("Cook completed. Open the output folder for packaged files and the cook report.");
                }
                else Fail(TEXT("The cook helper did not report a successful package. Check Result.json."));
            }
            else Fail(TEXT("The cook ended without a result report. Check Console.txt."));
        }
    }

    FString DisplayStatus() const
    {
        if (!bRunning || !bCooking) return Status;
        const int32 Dots = 1 + static_cast<int32>(FPlatformTime::Seconds() * 2.0) % 3;
        const FString Heading = TEXT("Cooking, bear with me :D ") + FString::ChrN(Dots, TEXT('.'));
        if (Status.StartsWith(TEXT("Compiling shaders:"))) return Heading + TEXT("\n") + Status;
        return Heading + TEXT("\nProject copy ready. You can continue editing the source project.");
    }

    FString DisplayElapsed(double Now) const
    {
        if (StartedAt < 0.0) return FString();
        const double End = bRunning ? Now : FinishedAt;
        const int64 Seconds = static_cast<int64>(FMath::Max(0.0, End - StartedAt));
        return FString::Printf(TEXT("Elapsed %lld:%02lld:%02lld"), Seconds / 3600, Seconds / 60 % 60, Seconds % 60);
    }

    void Cancel()
    {
        if (!Process || !bRunning || bCancelling) return;
        bCancelling = true;
        bCooking = false;
        Process->Cancel(true);
        Status = TEXT("Cancelling cook...");
    }
    void Stop()
    {
        if (Process) { Process->Cancel(true); Process.Reset(); }
        if (bRunning) FinishedAt = FPlatformTime::Seconds();
        bRunning = false;
        bCooking = false;
    }
    bool Fail(const FString& Message) { Status = Message; bError = true; return false; }
    bool IsShowingUatLog() const { return LogTail.IsUatLog(); }
    bool bRunning = false;
    bool bError = false;
    FString LastOutput;
    FString Status = TEXT("Ready. Choose your mod folder and cook.");
    FString Output;
    uint64 LogRevision = 0;

private:
#if WITH_DEV_AUTOMATION_TESTS
    friend class FCookProgressPanelTest;
#endif
    bool bCooking = false;
    bool bCancelling = false;
    double StartedAt = -1.0;
    double FinishedAt = -1.0;
    double NextLogRead = 0.0;
    FCookLogTail LogTail;
    TUniquePtr<FMonitoredProcess> Process;
    TSharedPtr<FProcessState, ESPMode::ThreadSafe> State;
};

#if WITH_DEV_AUTOMATION_TESTS
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FCookProgressPanelTest, "Limelight.ShaderCooker.QuietUatProgress",
    EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FCookProgressPanelTest::RunTest(const FString& Parameters)
{
    FCookSession Session;
    Session.LastOutput = FPaths::Combine(FPaths::AutomationTransientDir(), FGuid::NewGuid().ToString(EGuidFormats::Digits));
    const FString LogFolder = FPaths::Combine(Session.LastOutput, TEXT("UATLogs/attempt-1"));
    const FString Log = FPaths::Combine(LogFolder, TEXT("Log.txt"));
    IFileManager& Files = IFileManager::Get();
    Files.MakeDirectory(*LogFolder, true);
    ON_SCOPE_EXIT
    {
        Files.Delete(*Log);
        Files.DeleteDirectory(*LogFolder);
        Files.DeleteDirectory(*FPaths::GetPath(LogFolder));
        Files.DeleteDirectory(*Session.LastOutput);
    };
    if (!TestTrue(TEXT("Write a quiet UAT log"), FFileHelper::SaveStringToFile(TEXT("Sandbox cleanup\n"), *Log, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM))) return false;

    Session.bRunning = true;
    Session.StartedAt = FPlatformTime::Seconds();
    Session.State = MakeShared<FProcessState, ESPMode::ThreadSafe>();
    Session.Tick();
    TestEqual(TEXT("Show the UAT file"), Session.Output, FString(TEXT("Sandbox cleanup\n")));
    const uint64 PreviousRevision = Session.LogRevision;
    Session.State->Lines.Enqueue(TEXT("LIMELIGHT_STATUS Compiling shaders: 7 completed. Elapsed 0:00:05."));
    Session.Tick();
    TestTrue(TEXT("A cooker update refreshes the panel while UAT is quiet"), Session.LogRevision > PreviousRevision);
    TestEqual(TEXT("Progress follows the UAT lines"), Session.Output, FString(TEXT("Sandbox cleanup\n[Cooker] Compiling shaders: 7 completed. Elapsed 0:00:05.\n")));
    TestFalse(TEXT("The status does not show the sampled elapsed time"), Session.DisplayStatus().Contains(TEXT("Elapsed")));
    TestEqual(TEXT("Elapsed time after one second"), Session.DisplayElapsed(Session.StartedAt + 1.25), FString(TEXT("Elapsed 0:00:01")));
    TestEqual(TEXT("The next second needs no progress update"), Session.DisplayElapsed(Session.StartedAt + 2.25), FString(TEXT("Elapsed 0:00:02")));
    Session.State->ExitCode.Store(-2);
    Session.Tick();
    TestEqual(TEXT("The elapsed time freezes when the cook exits"), Session.DisplayElapsed(Session.FinishedAt + 10.0), Session.DisplayElapsed(Session.FinishedAt));
    return true;
}
#endif

class SCookerPanel : public SCompoundWidget
{
public:
    SLATE_BEGIN_ARGS(SCookerPanel) {} SLATE_END_ARGS()
    void Construct(const FArguments& Args, TSharedRef<FCookSession> InSession)
    {
        Session = InSession;
        FString Folder = TEXT("/Game");
        FString OutputRoot = FullPath(FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("ShaderCooker/Builds")));
        GConfig->GetString(SettingsSection, TEXT("ContentFolder"), Folder, GEditorPerProjectIni);
        GConfig->GetString(SettingsSection, TEXT("OutputRoot"), OutputRoot, GEditorPerProjectIni);
        GConfig->GetString(SettingsSection, TEXT("Mode"), Mode, GEditorPerProjectIni);
        GConfig->GetString(SettingsSection, TEXT("AssetPath"), AssetPath, GEditorPerProjectIni);
        GConfig->GetString(SettingsSection, TEXT("MapPath"), MapPath, GEditorPerProjectIni);
        ModeOptions = {MakeShared<FString>(TEXT("Data asset")), MakeShared<FString>(TEXT("Content folder")), MakeShared<FString>(TEXT("Cook All")), MakeShared<FString>(TEXT("Arena map"))};
        const int32 ModeIndex = Mode == TEXT("Asset") ? 0 : Mode == TEXT("All") ? 2 : Mode == TEXT("Map") ? 3 : 1;
        ChildSlot
        [
            SNew(SBorder).Padding(20)
            [
                SNew(SScrollBox)
                + SScrollBox::Slot()
                [
                    SNew(SVerticalBox)
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 8)
                    [ SNew(STextBlock).Text(LOCTEXT("Title", "Cook for Dead as Disco")).TextStyle(FAppStyle::Get(), "DetailsView.CategoryTextStyle") ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 14)
                    [ SNew(STextBlock).Text(LOCTEXT("Scope", "For Dead as Disco CL-35029 and Epic UE 5.7.4. Preserves lit materials, translucency and the material's DBuffer decal response.")).AutoWrapText(true) ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 14)
                    [ SNew(STextBlock).Text(FText::FromString(FullPath(FPaths::GetProjectFilePath()))).AutoWrapText(true).ColorAndOpacity(FSlateColor::UseSubduedForeground()) ]
                    + SVerticalBox::Slot().AutoHeight()[ SNew(STextBlock).Text(LOCTEXT("ModeLabel", "What to cook")) ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 4, 0, 12)
                    [ SNew(SComboBox<TSharedPtr<FString>>).OptionsSource(&ModeOptions).InitiallySelectedItem(ModeOptions[ModeIndex]).IsEnabled_Lambda([this] { return !Session->bRunning; })
                        .OnGenerateWidget_Lambda([](TSharedPtr<FString> Item) { return SNew(STextBlock).Text(FText::FromString(*Item)); })
                        .OnSelectionChanged_Lambda([this](TSharedPtr<FString> Item, ESelectInfo::Type) { Mode = Item == ModeOptions[0] ? TEXT("Asset") : Item == ModeOptions[2] ? TEXT("All") : Item == ModeOptions[3] ? TEXT("Map") : TEXT("Folder"); bArenaCook = false; })
                        [ SNew(STextBlock).Text_Lambda([this] { return FText::FromString(Mode == TEXT("Asset") ? TEXT("Data asset") : Mode == TEXT("All") ? TEXT("Cook All") : Mode == TEXT("Map") ? TEXT("Arena map") : TEXT("Content folder")); }) ] ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 12)
                    [ SNew(SBox).Visibility_Lambda([this] { return Mode == TEXT("Asset") ? EVisibility::Visible : EVisibility::Collapsed; })
                        [ SNew(SObjectPropertyEntryBox).AllowedClass(UDataAsset::StaticClass()).AllowClear(true).ObjectPath_Lambda([this] { return AssetPath; }).IsEnabled_Lambda([this] { return !Session->bRunning; })
                            .OnObjectChanged_Lambda([this](const FAssetData& Asset) { AssetPath = Asset.GetSoftObjectPath().ToString(); }) ] ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 12)
                    [ SNew(SBox).Visibility_Lambda([this] { return Mode == TEXT("Map") ? EVisibility::Visible : EVisibility::Collapsed; })
                        [ SNew(SObjectPropertyEntryBox).AllowedClass(UWorld::StaticClass()).AllowClear(true).ObjectPath_Lambda([this] { return MapPath; }).IsEnabled_Lambda([this] { return !Session->bRunning; })
                            .OnObjectChanged_Lambda([this](const FAssetData& Asset) { MapPath = Asset.GetSoftObjectPath().ToString(); }) ] ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 4, 0, 5)
                    [
                        SNew(SHorizontalBox).Visibility_Lambda([this] { return Mode == TEXT("Folder") ? EVisibility::Visible : EVisibility::Collapsed; })
                        + SHorizontalBox::Slot().FillWidth(1)[ SAssignNew(ContentBox, SEditableTextBox).Text(FText::FromString(Folder)).IsEnabled_Lambda([this] { return !Session->bRunning; }) ]
                        + SHorizontalBox::Slot().AutoWidth().Padding(6, 0)[ SNew(SButton).Text(LOCTEXT("BrowseContent", "Browse...")).IsEnabled_Lambda([this] { return !Session->bRunning; }).OnClicked(this, &SCookerPanel::BrowseContent) ]
                    ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 14)
                    [ SNew(STextBlock).Text_Lambda([this] { return FText::FromString(Mode == TEXT("All") ? TEXT("Cooks the whole project, including unused content. Existing never-cook rules and chunk labels still apply.") : TEXT("Includes the selected asset or folder and its referenced dependencies. Existing packaging rules and chunk labels still apply.")); }).AutoWrapText(true).ColorAndOpacity(FSlateColor::UseSubduedForeground()) ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 14)
                    [ SNew(SCheckBox).Visibility_Lambda([this] { return Mode == TEXT("Map") ? EVisibility::Collapsed : EVisibility::Visible; })
                        .IsEnabled_Lambda([this] { return !Session->bRunning; })
                        .IsChecked_Lambda([this] { return bArenaCook ? ECheckBoxState::Checked : ECheckBoxState::Unchecked; })
                        .OnCheckStateChanged_Lambda([this](ECheckBoxState State) { bArenaCook = State == ECheckBoxState::Checked; })
                        [ SNew(STextBlock).Text(LOCTEXT("ArenaCook", "Cook as an arena")).ToolTipText(LOCTEXT("ArenaCookHelp", "Enable this when the selected asset label, folder or whole project is an arena mod. Arena map mode enables it automatically.")) ] ]
                    + SVerticalBox::Slot().AutoHeight()[ SNew(STextBlock).Text(LOCTEXT("OutputLabel", "Output folder")) ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 4, 0, 14)
                    [
                        SNew(SHorizontalBox)
                        + SHorizontalBox::Slot().FillWidth(1)[ SAssignNew(OutputBox, SEditableTextBox).Text(FText::FromString(OutputRoot)).IsEnabled_Lambda([this] { return !Session->bRunning; }) ]
                        + SHorizontalBox::Slot().AutoWidth().Padding(6, 0)[ SNew(SButton).Text(LOCTEXT("BrowseOutput", "Browse...")).IsEnabled_Lambda([this] { return !Session->bRunning; }).OnClicked(this, &SCookerPanel::BrowseOutput) ]
                    ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 14)
                    [ SAssignNew(DebugBox, SCheckBox).IsEnabled_Lambda([this] { return !Session->bRunning; })
                        [ SNew(STextBlock).Text(LOCTEXT("Debug", "Save shader debug files (larger output, for Henreh's sanity)")).AutoWrapText(true) ] ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 10)
                    [
                        SNew(SHorizontalBox)
                        + SHorizontalBox::Slot().AutoWidth()
                        [ SNew(SButton).HAlign(HAlign_Center).VAlign(VAlign_Center).ButtonStyle(FAppStyle::Get(), "PrimaryButton").ContentPadding(FMargin(18, 8)).Text(LOCTEXT("Cook", "Cook Mod")).IsEnabled_Lambda([this] { return !Session->bRunning; }).OnClicked_Lambda([this] {
                            if (Session->Start(Mode, Mode == TEXT("Map") ? MapPath : AssetPath, ContentBox->GetText().ToString(), OutputBox->GetText().ToString(), DebugBox->IsChecked(), bArenaCook)) bFollowLog = true;
                            return FReply::Handled();
                        }) ]
                        + SHorizontalBox::Slot().AutoWidth().Padding(8, 0)
                        [ SNew(SButton).HAlign(HAlign_Center).VAlign(VAlign_Center).Text(LOCTEXT("Cancel", "Cancel")).IsEnabled_Lambda([this] { return Session->bRunning; }).OnClicked_Lambda([this] { Session->Cancel(); return FReply::Handled(); }) ]
                        + SHorizontalBox::Slot().AutoWidth()
                        [ SNew(SButton).HAlign(HAlign_Center).VAlign(VAlign_Center).Text(LOCTEXT("Open", "Open output folder")).IsEnabled_Lambda([this] { return !Session->LastOutput.IsEmpty() && IFileManager::Get().DirectoryExists(*Session->LastOutput); }).OnClicked_Lambda([this] { FPlatformProcess::ExploreFolder(*Session->LastOutput); return FReply::Handled(); }) ]
                    ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 12)
                    [ SNew(STextBlock).Text_Lambda([this] { return FText::FromString(Session->DisplayStatus()); }).ColorAndOpacity_Lambda([this] { return Session->bError ? FSlateColor(FLinearColor(1, 0.3f, 0.2f)) : FSlateColor::UseForeground(); }).AutoWrapText(true) ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 4)
                    [ SNew(STextBlock).Text_Lambda([this] { return FText::FromString(Session->DisplayElapsed(FPlatformTime::Seconds())); }) ]
                    + SVerticalBox::Slot().AutoHeight().Padding(0, 0, 0, 4)
                    [ SNew(STextBlock).Text_Lambda([this] { return Session->IsShowingUatLog() ? LOCTEXT("UatLog", "UAT log and cooker progress") : LOCTEXT("CookerLog", "Cooker log"); }) ]
                    + SVerticalBox::Slot().AutoHeight()
                    [ SNew(SBox).HeightOverride(230)
                        [ SAssignNew(LogBox, SMultiLineEditableTextBox).IsReadOnly(true)
                            .OnVScrollBarUserScrolled_Lambda([this](float Offset) { bFollowLog = FMath::IsNearlyEqual(Offset, 1.0f); }) ] ]
                ]
            ]
        ];
    }

    virtual void Tick(const FGeometry& Geometry, const double CurrentTime, const float DeltaTime) override
    {
        SCompoundWidget::Tick(Geometry, CurrentTime, DeltaTime);
        if (DisplayedLogRevision == Session->LogRevision) return;
        DisplayedLogRevision = Session->LogRevision;
        LogBox->SetText(FText::FromString(Session->Output));
        if (bFollowLog) LogBox->ScrollTo(ETextLocation::EndOfDocument);
    }

private:
    FReply BrowseContent()
    {
        FString Selected;
        if (Browse(FullPath(FPaths::ProjectContentDir()), Selected))
        {
            FString Root = FullPath(FPaths::ProjectContentDir());
            Root.RemoveFromEnd(TEXT("/"));
            FString Relative = FullPath(Selected);
            Relative.RemoveFromEnd(TEXT("/"));
            if (Relative.Equals(Root, ESearchCase::IgnoreCase)) ContentBox->SetText(FText::FromString(TEXT("/Game")));
            else if (FPaths::IsUnderDirectory(Relative, Root))
            {
                ContentBox->SetText(FText::FromString(TEXT("/Game/") + Relative.RightChop(Root.Len() + 1)));
            }
            else Session->Fail(TEXT("Choose a folder inside this project's Content directory."));
        }
        return FReply::Handled();
    }
    FReply BrowseOutput()
    {
        FString Selected;
        if (Browse(OutputBox->GetText().ToString(), Selected)) OutputBox->SetText(FText::FromString(Selected));
        return FReply::Handled();
    }
    bool Browse(const FString& Initial, FString& Selected)
    {
        IDesktopPlatform* Desktop = FDesktopPlatformModule::Get();
        return Desktop && Desktop->OpenDirectoryDialog(FSlateApplication::Get().FindBestParentWindowHandleForDialogs(nullptr), TEXT("Choose folder"), Initial, Selected);
    }
    TSharedPtr<FCookSession> Session;
    TSharedPtr<SEditableTextBox> ContentBox, OutputBox;
    TSharedPtr<SCheckBox> DebugBox;
    TSharedPtr<SMultiLineEditableTextBox> LogBox;
    uint64 DisplayedLogRevision = MAX_uint64;
    bool bFollowLog = true;
    FString Mode = TEXT("Asset");
    FString AssetPath;
    FString MapPath;
    bool bArenaCook = false;
    TArray<TSharedPtr<FString>> ModeOptions;
};
}

class FLimelightShaderCookerModule : public IModuleInterface
{
public:
    bool SupportsDynamicReloading() override { return false; }
    void StartupModule() override
    {
        Session = MakeShared<FCookSession>();
        TickHandle = FTSTicker::GetCoreTicker().AddTicker(FTickerDelegate::CreateLambda([this](float) { Session->Tick(); return true; }));
        FGlobalTabmanager::Get()->RegisterNomadTabSpawner(CookerTab, FOnSpawnTab::CreateLambda([this](const FSpawnTabArgs&) { return SNew(SDockTab).TabRole(ETabRole::NomadTab)[ SNew(SCookerPanel, Session.ToSharedRef()) ]; }))
            .SetDisplayName(LOCTEXT("Tab", "Limelight Shader Cooker")).SetMenuType(ETabSpawnerMenuType::Hidden);
        UToolMenus::RegisterStartupCallback(FSimpleMulticastDelegate::FDelegate::CreateRaw(this, &FLimelightShaderCookerModule::RegisterMenus));
    }
    void ShutdownModule() override
    {
        UToolMenus::UnRegisterStartupCallback(this);
        UToolMenus::UnregisterOwner(this);
        FGlobalTabmanager::Get()->UnregisterNomadTabSpawner(CookerTab);
        FTSTicker::GetCoreTicker().RemoveTicker(TickHandle);
        if (Session) Session->Stop();
        Session.Reset();
    }
private:
    void RegisterMenus()
    {
        FToolMenuOwnerScoped Owner(this);
        UToolMenus::Get()->ExtendMenu(TEXT("LevelEditor.MainMenu.Tools"))->FindOrAddSection(TEXT("Programming")).AddMenuEntry(
            TEXT("LimelightShaderCooker"), LOCTEXT("Menu", "Cook for Dead as Disco"), LOCTEXT("Tooltip", "Open the Limelight Shader Cooker."),
            FSlateIcon(FAppStyle::GetAppStyleSetName(), TEXT("MainFrame.PackageProject")),
            FUIAction(FExecuteAction::CreateLambda([] { FGlobalTabmanager::Get()->TryInvokeTab(CookerTab); })));
    }
    TSharedPtr<FCookSession> Session;
    FTSTicker::FDelegateHandle TickHandle;
};

IMPLEMENT_MODULE(FLimelightShaderCookerModule, LimelightShaderCooker)
#undef LOCTEXT_NAMESPACE
