#include "CookLogTail.h"

#include "Containers/StringConv.h"
#include "HAL/PlatformFileManager.h"
#include "Misc/Paths.h"

namespace
{
constexpr int32 LogTailLimit = 64 * 1024;
}

bool FCookLogTail::Update(const FString& RunFolder, bool bFinished, FString& Text)
{
    IPlatformFile& Files = FPlatformFileManager::Get().GetPlatformFile();
    const TCHAR* Sources[] = {
        TEXT("UATLogs/attempt-2/Log.txt"),
        TEXT("UATLogs/attempt-1/Log.txt"),
        TEXT("UATLogs/Log.txt"),
        TEXT("Console.txt")
    };
    FString Path;
    for (const TCHAR* Source : Sources)
    {
        FString Candidate = FPaths::Combine(RunFolder, Source);
        if (Files.FileSize(*Candidate) <= 0) continue;
        Path = MoveTemp(Candidate);
        break;
    }
    if (Path.IsEmpty()) return false;

    using ERead = IPlatformFile::EOpenReadFlags;
    FFileOpenResult Open = Files.OpenRead(*Path, ERead::AllowWrite | ERead::AllowDelete);
    if (Open.HasError()) return false;
    IFileHandle& File = *Open.GetValue();
    const int64 Size = File.Size();
    if (Size <= 0) return false;

    const bool bReset = Path != Filename || Size < Offset;
    const int64 PreviousOffset = bReset ? 0 : Offset;
    const int64 Start = FMath::Max(PreviousOffset, Size - LogTailLimit);
    if (Start == Size) return false;

    TArray<uint8> Bytes;
    Bytes.SetNumUninitialized(static_cast<int32>(Size - Start));
    if (!File.Seek(Start) || !File.Read(Bytes.GetData(), Bytes.Num())) return false;

    int32 End = Bytes.Num();
    // I leave a partial line for the next read so an unfinished UTF-8 character stays intact.
    if (!bFinished)
        while (End > 0 && Bytes[End - 1] != '\n') --End;

    int32 First = 0;
    if (Start > PreviousOffset)
    {
        while (First < End && Bytes[First] != '\n') ++First;
        if (First < End) ++First;
    }
    else if (Start == 0 && End >= 3 && Bytes[0] == 0xef && Bytes[1] == 0xbb && Bytes[2] == 0xbf)
    {
        First = 3;
    }

    if (bReset || Start > PreviousOffset) Text.Reset();
    Filename = MoveTemp(Path);
    Offset = Start + End;
    if (First < End)
    {
        const auto Converted = StringCast<TCHAR>(reinterpret_cast<const UTF8CHAR*>(Bytes.GetData() + First), End - First);
        Text.AppendChars(Converted.Get(), Converted.Length());
        Trim(Text);
    }
    return bReset || Start > PreviousOffset || First < End;
}

void FCookLogTail::Trim(FString& Text)
{
    if (Text.Len() <= LogTailLimit) return;
    const int32 Excess = Text.Len() - LogTailLimit;
    const int32 Newline = Text.Find(TEXT("\n"), ESearchCase::CaseSensitive, ESearchDir::FromStart, Excess);
    Text.RightChopInline(Newline == INDEX_NONE ? Excess : Newline + 1, EAllowShrinking::No);
}
