#include "CookLogTail.h"

#if WITH_DEV_AUTOMATION_TESTS

#include "HAL/FileManager.h"
#include "HAL/PlatformFileManager.h"
#include "Misc/AutomationTest.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Misc/ScopeExit.h"

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FCookLogTailTest, "Limelight.ShaderCooker.LiveUatLog",
    EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FCookLogTailTest::RunTest(const FString& Parameters)
{
    const FString Root = FPaths::Combine(FPaths::AutomationTransientDir(), FGuid::NewGuid().ToString(EGuidFormats::Digits));
    const FString Console = FPaths::Combine(Root, TEXT("Console.txt"));
    const FString FirstAttempt = FPaths::Combine(Root, TEXT("UATLogs/attempt-1/Log.txt"));
    const FString SecondAttempt = FPaths::Combine(Root, TEXT("UATLogs/attempt-2/Log.txt"));
    IFileManager& Files = IFileManager::Get();
    Files.MakeDirectory(*FPaths::GetPath(FirstAttempt), true);
    Files.MakeDirectory(*FPaths::GetPath(SecondAttempt), true);
    ON_SCOPE_EXIT
    {
        Files.Delete(*Console);
        Files.Delete(*FirstAttempt);
        Files.Delete(*SecondAttempt);
        Files.DeleteDirectory(*FPaths::GetPath(FirstAttempt));
        Files.DeleteDirectory(*FPaths::GetPath(SecondAttempt));
        Files.DeleteDirectory(*FPaths::Combine(Root, TEXT("UATLogs")));
        Files.DeleteDirectory(*Root);
    };

    if (!TestTrue(TEXT("Write a cooker console log"), FFileHelper::SaveStringToFile(TEXT("Preparing the cook\n"), *Console, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM))) return false;
    FCookLogTail Tail;
    FString Text;
    TestTrue(TEXT("Read the cooker log before UAT starts"), Tail.Update(Root, false, Text));
    TestEqual(TEXT("Startup output"), Text, FString(TEXT("Preparing the cook\n")));
    TestFalse(TEXT("An unchanged file does not update the display"), Tail.Update(Root, false, Text));

    {
        IPlatformFile& Platform = FPlatformFileManager::Get().GetPlatformFile();
        TUniquePtr<IFileHandle> Writer(Platform.OpenWrite(*FirstAttempt, false, true));
        if (!TestTrue(TEXT("Open UAT log with a live writer"), Writer.IsValid())) return false;
        const uint8 Initial[] = {'U', 'A', 'T', '\n', 'c', 'a', 'f', 0xc3};
        if (!TestTrue(TEXT("Write UAT startup and a partial UTF-8 line"), Writer->Write(Initial, sizeof(Initial)) && Writer->Flush())) return false;
        TestTrue(TEXT("Switch to the live UAT log"), Tail.Update(Root, false, Text));
        TestTrue(TEXT("Mark the active source as UAT"), Tail.IsUatLog());
        TestEqual(TEXT("Only complete lines appear"), Text, FString(TEXT("UAT\n")));

        const uint8 Next[] = {0xa9, '\n'};
        if (!TestTrue(TEXT("Complete the UTF-8 line"), Writer->Write(Next, sizeof(Next)) && Writer->Flush())) return false;
        TestTrue(TEXT("New lines arrive while UAT holds the file open"), Tail.Update(Root, false, Text));
        TestEqual(TEXT("Append the completed line once"), Text, FString(TEXT("UAT\ncaf\u00e9\n")));
    }

    if (!TestTrue(TEXT("Write the retry log"), FFileHelper::SaveStringToFile(TEXT("Retry\nExitCode=0"), *SecondAttempt, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM))) return false;
    TestTrue(TEXT("Follow the retry log"), Tail.Update(Root, false, Text));
    TestEqual(TEXT("The display switches to the current attempt"), Text, FString(TEXT("Retry\n")));
    TestTrue(TEXT("Read an unterminated final line after exit"), Tail.Update(Root, true, Text));
    TestEqual(TEXT("The final UAT result is visible"), Text, FString(TEXT("Retry\nExitCode=0")));
    return true;
}

#endif
