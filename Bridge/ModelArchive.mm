#import "ModelArchive.h"
#include <sys/stat.h>
// macOS ships libarchive but recent SDKs omit its headers. Declare only the
// stable public C ABI used here; link the OS library, with no Homebrew runtime.
extern "C" {
struct archive; struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
}
static const int ARCHIVE_OK = 0, ARCHIVE_EOF = 1;
static const mode_t AE_IFREG = S_IFREG, AE_IFDIR = S_IFDIR;

@implementation L2DModelArchive
+ (BOOL)extractPath:(NSString *)path toDirectory:(NSString *)directory error:(NSError **)error {
    struct archive *reader = archive_read_new();
    archive_read_support_format_zip(reader);
    NSString *failure = nil;
    unsigned long long total = 0;
    NSUInteger count = 0;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (archive_read_open_filename(reader, path.fileSystemRepresentation, 65536) != ARCHIVE_OK) {
        failure = @"无法读取模型包：文件不是有效的 ZIP 容器，或包版本暂不支持。";
    } else {
        struct archive_entry *entry;
        int status;
        while ((status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
            const char *rawName = archive_entry_pathname_utf8(entry);
            if (!rawName) rawName = archive_entry_pathname(entry);
            NSString *name = rawName ? [NSString stringWithUTF8String:rawName] : nil;
            NSArray *parts = [name componentsSeparatedByString:@"/"];
            mode_t type = archive_entry_filetype(entry);
            NSString *canonical = name.stringByStandardizingPath.lowercaseString;
            if (!name.length || name.isAbsolutePath || [parts containsObject:@".."] ||
                [name containsString:@"\\"] || [name containsString:@":"] ||
                archive_entry_symlink(entry) || archive_entry_hardlink(entry) ||
                (type != AE_IFREG && type != AE_IFDIR) || [seen containsObject:canonical]) {
                failure = @"模型包包含不安全、重复或不支持的文件路径。"; break;
            }
            [seen addObject:canonical];
            if (++count > 20000 || archive_entry_size(entry) < 0 ||
                (unsigned long long)archive_entry_size(entry) > 512ULL * 1024 * 1024) {
                failure = @"模型包超过限制（20,000 项或解包后 512 MiB）。"; break;
            }
            NSString *target = [directory stringByAppendingPathComponent:name];
            NSFileManager *fm = NSFileManager.defaultManager;
            if (type == AE_IFDIR) {
                if (![fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:error]) { failure = @"无法创建模型目录。"; break; }
                continue;
            }
            if (![fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] ||
                ![fm createFileAtPath:target contents:nil attributes:nil]) { failure = @"无法写入模型资源。"; break; }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:target];
            if (!handle) { failure = @"无法写入模型资源。"; break; }
            char buffer[65536];
            ssize_t size;
            while ((size = archive_read_data(reader, buffer, sizeof buffer)) > 0) {
                total += size;
                if (total > 512ULL * 1024 * 1024) { failure = @"模型包解包后超过 512 MiB。"; break; }
                if (![handle writeData:[NSData dataWithBytes:buffer length:size] error:error]) { failure = @"无法写入模型资源。"; break; }
            }
            [handle closeFile];
            if (size < 0) failure = @"模型包损坏、受密码保护或压缩方式不支持。";
            if (failure) break;
        }
        if (!failure && status != ARCHIVE_EOF) failure = @"模型包目录损坏。";
    }
    archive_read_free(reader);
    if (failure && error) *error = [NSError errorWithDomain:@"Lite2D.Import" code:1 userInfo:@{NSLocalizedDescriptionKey:failure}];
    return failure == nil;
}
@end
