#pragma once

#include "CoreMinimal.h"

class FCookLogTail
{
public:
    bool Update(const FString& RunFolder, bool bFinished, FString& Text);
    bool HasFile() const { return !Filename.IsEmpty(); }
    bool IsUatLog() const { return Filename.EndsWith(TEXT("/Log.txt")); }
    static void Trim(FString& Text);

private:
    FString Filename;
    int64 Offset = 0;
};
