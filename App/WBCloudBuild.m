//
//  WBCloudBuild.m
//  Workbench —— GitHub Actions 云端构建
//

#import "WBCloudBuild.h"
#import "GitService.h"
#import "SPCompat.h"

static NSString *const WBCloudRepoKey = @"Workbench.cloudRepo";
static NSString *const WBCloudRefKey = @"Workbench.cloudRef";
static NSString *const WBCloudRootlessKey = @"Workbench.cloudRootless";
static NSString *const WBCloudWorkflowName = @"workbench-cloudbuild.yml";

@implementation WBCloudBuild

+ (NSString *)workflowFileName { return WBCloudWorkflowName; }

+ (NSString *)repository {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:WBCloudRepoKey];
    return v.length ? v : nil;
}

+ (void)setRepository:(NSString *)repository {
    [NSUserDefaults.standardUserDefaults setObject:(repository ?: @"") forKey:WBCloudRepoKey];
}

+ (NSString *)reference {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:WBCloudRefKey];
    return v.length ? v : @"main";
}

+ (void)setReference:(NSString *)reference {
    NSString *v = [reference stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [NSUserDefaults.standardUserDefaults setObject:(v.length ? v : @"main") forKey:WBCloudRefKey];
}

+ (BOOL)rootless {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:WBCloudRootlessKey];
    return v == nil ? YES : [v boolValue];
}

+ (void)setRootless:(BOOL)rootless {
    [NSUserDefaults.standardUserDefaults setBool:rootless forKey:WBCloudRootlessKey];
}

+ (NSString *)savedToken {
    NSDictionary *credential = [TMCGitService credentialForURL:@"https://github.com"];
    NSString *token = credential[@"token"];
    if (![token isKindOfClass:NSString.class] || token.length == 0) return nil;
    return token;
}

#pragma mark - Workflow 内容

// Theos 工程的通用云端构建：Linux/macOS runner 上拉 theos、make package、回传 deb。
// 有意保持最小：不注入脚本、不读取仓库里的自定义命令，避免把云端 runner 当执行器。
+ (NSString *)workflowYAML {
    return @"name: Workbench Cloud Build\n"
            @"on:\n"
            @"  workflow_dispatch:\n"
            @"    inputs:\n"
            @"      scheme:\n"
            @"        description: 'rootless or rootful'\n"
            @"        required: false\n"
            @"        default: 'rootless'\n"
            @"jobs:\n"
            @"  build:\n"
            @"    runs-on: macos-14\n"
            @"    timeout-minutes: 45\n"
            @"    steps:\n"
            @"      - uses: actions/checkout@v4\n"
            @"        with:\n"
            @"          submodules: recursive\n"
            @"      - name: Install toolchain\n"
            @"        run: |\n"
            @"          set -euo pipefail\n"
            @"          brew install ldid dpkg make xz || true\n"
            @"          git clone --recursive --depth 1 https://github.com/theos/theos.git \"$RUNNER_TEMP/theos\"\n"
            @"          echo \"THEOS=$RUNNER_TEMP/theos\" >> \"$GITHUB_ENV\"\n"
            @"      - name: Build package\n"
            @"        env:\n"
            @"          INPUT_SCHEME: ${{ inputs.scheme }}\n"
            @"        run: |\n"
            @"          set -euo pipefail\n"
            @"          if [ ! -f Makefile ]; then\n"
            @"            echo \"::error::仓库根目录没有 Makefile（Theos 工程）\"\n"
            @"            exit 1\n"
            @"          fi\n"
            @"          if [ \"$INPUT_SCHEME\" = \"rootless\" ]; then\n"
            @"            make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless\n"
            @"          else\n"
            @"            make package FINALPACKAGE=1\n"
            @"          fi\n"
            @"      - name: Upload package\n"
            @"        uses: actions/upload-artifact@v4\n"
            @"        with:\n"
            @"          name: package\n"
            @"          path: |\n"
            @"            packages/*.deb\n"
            @"            *.deb\n"
            @"          if-no-files-found: error";
}

#pragma mark - HTTP

+ (NSMutableURLRequest *)request:(NSString *)url method:(NSString *)method token:(NSString *)token {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.HTTPMethod = method;
    request.timeoutInterval = 30;
    if (token.length) {
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    }
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"Workbench-CloudBuild" forHTTPHeaderField:@"User-Agent"];
    return request;
}

+ (NSError *)errorWith:(NSString *)message status:(NSInteger)status body:(nullable NSData *)body {
    NSString *detail = nil;
    if (body.length) {
        id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        if ([json isKindOfClass:NSDictionary.class] && [json[@"message"] isKindOfClass:NSString.class]) {
            detail = json[@"message"];
        }
    }
    NSString *text = detail.length ? [NSString stringWithFormat:@"%@（HTTP %ld）", detail, (long)status]
                                   : [NSString stringWithFormat:@"%@（HTTP %ld）", message, (long)status];
    return [NSError errorWithDomain:@"Workbench.CloudBuild" code:status
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

+ (void)send:(NSURLRequest *)request
  completion:(void (^)(NSData *_Nullable data, NSHTTPURLResponse *_Nullable response, NSError *_Nullable error))completion {
    [[NSURLSession.sharedSession dataTaskWithRequest:request
                                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(data, [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil, error);
        });
    }] resume];
}

#pragma mark - 写入 workflow

+ (void)installWorkflowWithToken:(NSString *)token
                      completion:(void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    NSString *repo = self.repository;
    if (!repo.length) {
        completion(nil, [NSError errorWithDomain:@"Workbench.CloudBuild" code:400
                                        userInfo:@{NSLocalizedDescriptionKey: @"请先填写仓库（owner/name）"}]);
        return;
    }
    if (!token.length) {
        completion(nil, [NSError errorWithDomain:@"Workbench.CloudBuild" code:401
                                        userInfo:@{NSLocalizedDescriptionKey: @"没有可用的 GitHub token，请先在 Git 页登录"}]);
        return;
    }
    NSString *path = [NSString stringWithFormat:@".github/workflows/%@", WBCloudWorkflowName];
    NSString *api = [NSString stringWithFormat:@"https://api.github.com/repos/%@/contents/%@", repo, path];
    NSMutableURLRequest *get = [self request:api method:@"GET" token:token];
    [self send:get completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSInteger status = response.statusCode;
        NSString *sha = nil;
        NSString *yaml = [self workflowYAML];
        if (status == 200) {
            id json = [NSJSONSerialization JSONObjectWithData:data ?: NSData.data options:0 error:NULL];
            if ([json isKindOfClass:NSDictionary.class]) {
                sha = [json[@"sha"] isKindOfClass:NSString.class] ? json[@"sha"] : nil;
                NSString *encoded = [json[@"content"] isKindOfClass:NSString.class] ? json[@"content"] : nil;
                NSString *clean = [encoded stringByReplacingOccurrencesOfString:@"\n" withString:@""];
                if (clean.length) {
                    NSData *existing = [[NSData alloc] initWithBase64EncodedString:clean options:0];
                    NSString *text = existing ? [[NSString alloc] initWithData:existing encoding:NSUTF8StringEncoding] : nil;
                    if ([text isEqualToString:yaml]) {
                        completion(@"工作流已是最新，无需写入", nil);
                        return;
                    }
                }
            }
        } else if (status != 404) {
            completion(nil, [self errorWith:@"读取工作流失败" status:status body:data]);
            return;
        }

        NSMutableDictionary *payload = [@{
            @"message": @"ci: add Workbench cloud build workflow",
            @"content": [[yaml dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0],
            @"branch": self.reference ?: @"main",
        } mutableCopy];
        if (sha.length) payload[@"sha"] = sha;
        NSMutableURLRequest *put = [self request:api method:@"PUT" token:token];
        [put setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        put.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
        [self send:put completion:^(NSData *putData, NSHTTPURLResponse *putResponse, NSError *putError) {
            if (putError) { completion(nil, putError); return; }
            if (putResponse.statusCode / 100 != 2) {
                completion(nil, [self errorWith:@"写入工作流失败" status:putResponse.statusCode body:putData]);
                return;
            }
            completion(sha.length ? @"工作流已更新" : @"工作流已创建", nil);
        }];
    }];
}

#pragma mark - 触发与状态

+ (void)dispatchWithToken:(NSString *)token completion:(void (^)(NSError *_Nullable))completion {
    NSString *repo = self.repository;
    if (!repo.length || !token.length) {
        completion([NSError errorWithDomain:@"Workbench.CloudBuild" code:400
                                   userInfo:@{NSLocalizedDescriptionKey: @"请先填写仓库并登录 GitHub"}]);
        return;
    }
    NSString *api = [NSString stringWithFormat:
                     @"https://api.github.com/repos/%@/actions/workflows/%@/dispatches", repo, WBCloudWorkflowName];
    NSMutableURLRequest *request = [self request:api method:@"POST" token:token];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"ref": self.reference ?: @"main",
                           @"inputs": @{@"scheme": self.rootless ? @"rootless" : @"rootful"}};
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [self send:request completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (error) { completion(error); return; }
        if (response.statusCode / 100 != 2) {
            completion([self errorWith:@"触发失败（工作流是否已写入？）" status:response.statusCode body:data]);
            return;
        }
        completion(nil);
    }];
}

+ (void)latestRunWithToken:(NSString *)token
                completion:(void (^)(NSDictionary *_Nullable, NSError *_Nullable))completion {
    NSString *repo = self.repository;
    if (!repo.length || !token.length) {
        completion(nil, [NSError errorWithDomain:@"Workbench.CloudBuild" code:400
                                        userInfo:@{NSLocalizedDescriptionKey: @"请先填写仓库并登录 GitHub"}]);
        return;
    }
    NSString *api = [NSString stringWithFormat:
                     @"https://api.github.com/repos/%@/actions/workflows/%@/runs?per_page=1", repo, WBCloudWorkflowName];
    [self send:[self request:api method:@"GET" token:token]
   completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        if (response.statusCode != 200) {
            completion(nil, [self errorWith:@"查询运行状态失败" status:response.statusCode body:data]);
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data ?: NSData.data options:0 error:NULL];
        NSArray *runs = [json isKindOfClass:NSDictionary.class] ? json[@"workflow_runs"] : nil;
        NSDictionary *run = [runs isKindOfClass:NSArray.class] && runs.count ? runs.firstObject : nil;
        completion([run isKindOfClass:NSDictionary.class] ? run : nil, nil);
    }];
}

+ (WBCloudBuildState)stateOfRun:(NSDictionary *)run {
    if (![run isKindOfClass:NSDictionary.class]) return WBCloudBuildStateUnknown;
    NSString *status = [run[@"status"] isKindOfClass:NSString.class] ? run[@"status"] : @"";
    NSString *conclusion = [run[@"conclusion"] isKindOfClass:NSString.class] ? run[@"conclusion"] : @"";
    if ([status isEqualToString:@"queued"]) return WBCloudBuildStateQueued;
    if ([status isEqualToString:@"in_progress"]) return WBCloudBuildStateInProgress;
    if ([conclusion isEqualToString:@"success"]) return WBCloudBuildStateSuccess;
    if (conclusion.length && ![conclusion isEqualToString:@"neutral"]) return WBCloudBuildStateFailure;
    return WBCloudBuildStateUnknown;
}

+ (NSString *)describeRun:(NSDictionary *)run {
    if (![run isKindOfClass:NSDictionary.class]) return @"还没有云端构建记录";
    NSString *status = [run[@"status"] isKindOfClass:NSString.class] ? run[@"status"] : @"unknown";
    NSString *conclusion = [run[@"conclusion"] isKindOfClass:NSString.class] ? run[@"conclusion"] : nil;
    NSString *created = [run[@"created_at"] isKindOfClass:NSString.class] ? run[@"created_at"] : @"";
    NSString *head = [run[@"head_branch"] isKindOfClass:NSString.class] ? run[@"head_branch"] : @"";
    NSString *state = [status isEqualToString:@"completed"] ? (conclusion ?: @"completed") : status;
    return [NSString stringWithFormat:@"%@ · %@ · %@", state, head, created];
}

@end
