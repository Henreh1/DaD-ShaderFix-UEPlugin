#include "Modules/ModuleManager.h"
#include "Dom/JsonObject.h"
#include "HAL/Event.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformProcess.h"
#include "HAL/Runnable.h"
#include "HAL/RunnableThread.h"
#include "Misc/CommandLine.h"
#include "Misc/CoreDelegates.h"
#include "Misc/FileHelper.h"
#include "Misc/Parse.h"
#include "Misc/Paths.h"
#include "Serialization/JsonSerializer.h"
#include "ShaderCompiler.h"

class FCookQueueSampler final : public FRunnable
{
public:
    FCookQueueSampler(FShaderCompilingManager* InManager, FString InPath, FString InToken)
        : Manager(InManager), Path(MoveTemp(InPath)), Token(MoveTemp(InToken))
    {
        Wake = FPlatformProcess::GetSynchEventFromPool(false);
    }

    ~FCookQueueSampler()
    {
        Stop();
        if (Thread)
        {
            Thread->WaitForCompletion();
            Thread.Reset();
        }
        FPlatformProcess::ReturnSynchEventToPool(Wake);
    }

    bool Start()
    {
        Thread.Reset(FRunnableThread::Create(this, TEXT("LimelightCookQueue"), 0, TPri_BelowNormal));
        return Thread.IsValid();
    }

    virtual uint32 Run() override
    {
        while (!bStopped.Load())
        {
            Save(true);
            Wake->Wait(2000);
        }
        Save(false);
        return 0;
    }

    virtual void Stop() override
    {
        bStopped.Store(true);
        Wake->Trigger();
    }

private:
    void Save(bool bRunning)
    {
        TSharedRef<FJsonObject> Value = MakeShared<FJsonObject>();
        Value->SetStringField(TEXT("CookToken"), Token);
        Value->SetStringField(TEXT("UpdatedUtc"), FDateTime::UtcNow().ToIso8601());
        Value->SetNumberField(TEXT("ProcessId"), FPlatformProcess::GetCurrentProcessId());
        Value->SetNumberField(TEXT("OutstandingJobs"), Manager->GetNumOutstandingJobs());
        Value->SetNumberField(TEXT("QueuedJobs"), Manager->GetNumPendingJobs());
        Value->SetBoolField(TEXT("Running"), bRunning);
        FString Json;
        FJsonSerializer::Serialize(Value, TJsonWriterFactory<>::Create(&Json));
        const FString Temporary = Path + TEXT(".tmp");
        if (FFileHelper::SaveStringToFile(Json, *Temporary, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM))
            IFileManager::Get().Move(*Path, *Temporary, true, false, false, true);
    }

    FShaderCompilingManager* Manager;
    FString Path;
    FString Token;
    FEvent* Wake = nullptr;
    TAtomic<bool> bStopped{false};
    TUniquePtr<FRunnableThread> Thread;
};

class FLimelightCookProgressModule final : public IModuleInterface
{
public:
    virtual void StartupModule() override
    {
        FString Commandlet;
        if (!IsRunningCommandlet() || !FParse::Value(FCommandLine::Get(), TEXT("run="), Commandlet)
            || !Commandlet.Equals(TEXT("Cook"), ESearchCase::IgnoreCase)) return;
        const FString ExpectedProject = FPlatformMisc::GetEnvironmentVariable(TEXT("LIMELIGHT_SHADER_COOK_PROJECT"));
        const FString Token = FPlatformMisc::GetEnvironmentVariable(TEXT("LIMELIGHT_SHADER_COOK_TOKEN"));
        if (ExpectedProject.IsEmpty() || Token.IsEmpty() || !GShaderCompilingManager) return;
        if (!FPaths::IsSamePath(FPaths::ConvertRelativePathToFull(ExpectedProject), FPaths::ConvertRelativePathToFull(FPaths::GetProjectFilePath()))) return;
        const FString Directory = FPaths::ConvertRelativePathToFull(FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("ShaderAdapter/Progress")));
        if (!IFileManager::Get().MakeDirectory(*Directory, true)) return;
        const FString Filename = FString::Printf(TEXT("Queue-%u.json"), FPlatformProcess::GetCurrentProcessId());
        Sampler = MakeUnique<FCookQueueSampler>(GShaderCompilingManager, FPaths::Combine(Directory, Filename), Token);
        if (!Sampler->Start()) { Sampler.Reset(); return; }
        PreExit = FCoreDelegates::OnPreExit.AddRaw(this, &FLimelightCookProgressModule::StopSampler);
    }

    virtual void ShutdownModule() override
    {
        FCoreDelegates::OnPreExit.Remove(PreExit);
        StopSampler();
    }

private:
    void StopSampler() { Sampler.Reset(); }
    TUniquePtr<FCookQueueSampler> Sampler;
    FDelegateHandle PreExit;
};

IMPLEMENT_MODULE(FLimelightCookProgressModule, LimelightCookProgress)
