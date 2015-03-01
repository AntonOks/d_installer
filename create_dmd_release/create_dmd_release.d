/+++
Prerequisites to Compile:
-------------------------
- Working D compiler

Prerequisites to Run:
---------------------
- Git
- Posix: Working gcc toolchain, including GNU make which is not installed on
  FreeBSD by default. On OSX, you can install the gcc toolchain through Xcode.
- Windows: Working DMC and MSVC toolchains. The default make must be DM make.
  Also, these environment variables must be set:
    VCDIR:  Visual C directory
    SDKDIR: Windows SDK directory
  Examples:
    set VCDIR=C:\Program Files (x86)\Microsoft Visual Studio 8\VC\
    set SDKDIR=C:\Program Files\Microsoft SDKs\Windows\v7.1\
- Windows: A version of OPTLINK with the /LA[RGEADDRESSAWARE] flag:
    <https://github.com/DigitalMars/optlink/commit/475bc5c1fa28eaf899ba4ac1dcfe2ab415db16c6>
- Windows: Microsoft's HTML Help Workshop on the PATH.

Typical Usage:
--------------
0. Obtain/install all prerequisites above.

1. (An unfortunately necessary step:) Download this file:
<http://semitwist.com/download/app/dmd-localextras.7z>
This contains the handful of files not under version control which are needed
by DMD. These are in directories named 'localextras-[os]' which match the
directory structure of DMD. Extract that file, and if necessary, update any
of the files to the latest versions, or add any new files as desired.

2. On 64-bit multilib versions of each supported OS (Windows, OSX, Linux, and
FreeBSD), genrate the platform-specific releases by running this (from
whatever directory you want the resulting archives placed):

$ [path-to]/create_dmd_release v2.064 --extras=[path-to]/localextras-[os] --archive

Optionally substitute "v2.064" with either "master" or the git tag name of the
desired release (must be at least "v2.064"). For beta releases, you can use a
branch name like "2.064".

If a working multilib system is any trouble, you can also build 32-bit and
64-bit versions separately using the --only-32 and --only-64 flags.

View all options with "create_dmd_release --help".

3. Distribute all the .zip and .7z files.

Extra notes:
------------
This tool keeps a deliberately strong separation between each of the main stages:

1. Clone   (from GitHub, into a temp dir)
2. Build   (compile everything, including docs, within the temp dir)
3. Package (generate an OS-specific release as a directory)
4. Archive (zip the OS-specific packaged release directory)

Aside from helping to ensure correctness, this separation means the process
can be resumed or restarted beginning at any of the above steps (see
the --skip-* flags in the --help screen).

The last step archive is not performed by default. To
perform the archive step, supply the --archive flag.
You can create an archive without repeating the earlier clone/build/package
steps by including the --skip-package flag.
+/

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.process;
import std.regex;
import std.stdio;
import std.string;
import std.typetuple;
import common;
version(Posix)
    import core.sys.posix.sys.stat;

immutable releaseBitSuffix32 = "-32"; // Ex: "dmd.v2.064.linux-32.zip"
immutable releaseBitSuffix64 = "-64";

version(Windows)
{
    // Cannot start with a period or MS's HTML Help Workshop will fail
    immutable defaultWorkDirName = "create_dmd_release";

    immutable makefile      = "win32.mak";
    immutable makefile64    = "win64.mak";
    immutable devNull       = "NUL";
    immutable exe           = ".exe";
    immutable lib           = ".lib";
    immutable obj           = ".obj";
    immutable dll           = ".dll";
    immutable generatedDocs = "dlang.org";
    immutable libPhobos32   = "phobos";
    immutable libPhobos64   = "phobos64";
    immutable build64BitTools = false;

    // Building Win64 druntime/phobos relies on an existing DMD, but there's no
    // official Win64 build/makefile of DMD. This is a hack to work around that.
    immutable lib64RequiresDmd32 = true;

    immutable osDirName     = "windows";
    immutable make          = "make";
    immutable suffix32      = "";   // bin/lib  TODO: adapt scripts to use 32
    immutable suffix64      = "64"; // bin64/lib64
}
else version(Posix)
{
    immutable defaultWorkDirName = ".create_dmd_release";
    immutable makefile      = "posix.mak";
    immutable makefile64    = "posix.mak";
    immutable devNull       = "/dev/null";
    immutable exe           = "";
    immutable lib           = ".a";
    immutable obj           = ".o";
    immutable generatedDocs = "dlang.org/web";
    immutable libPhobos32   = "libphobos2";
    immutable libPhobos64   = "libphobos2";
    immutable build64BitTools    = true;
    immutable lib64RequiresDmd32 = false;

    version(FreeBSD)
        immutable osDirName = "freebsd";
    else version(linux)
        immutable osDirName = "linux";
    else version(OSX)
        immutable osDirName = "osx";
    else
        static assert(false, "Unsupported system");

    version(FreeBSD)
        immutable make = "gmake";
    else
        immutable make = "make";

    version(OSX)
    {
        // TODO: adapt scripts to use 32/64
        immutable suffix32      = ""; // bin/lib
        immutable suffix64      = ""; // bin/lib
        immutable dll           = ".dylib";
    }
    else
    {
        immutable suffix32      = "32"; // bin32/lib32
        immutable suffix64      = "64"; // bin64/lib64
        immutable dll           = ".so";
    }
}
else
    static assert(false, "Unsupported system");

/// Fatal error message to exit cleanly with.
class Fail : Exception
{
    this(string msg) { super(msg); }
}

/// Minor convenience func
void fail(string msg)
{
    throw new Fail(msg);
}

enum Bits { bits32, bits64 }
string toString(Bits bits)
{
    return bits == Bits.bits32? "32-bit" : "64-bit";
}

void showHelp()
{
    writeln((`
        Create DMD Release - Build: ` ~ __TIMESTAMP__ ~ `
        Usage:   create_dmd_release --extras=path [options] TAG_OR_BRANCH [options]
        Example: create_dmd_release --extras=`~osDirName~`-extra --archive v2.064

        Generates a platform-specific DMD release as a directory tree.
        Optionally, it can also generate archived releases.

        TAG_OR_BRANCH:     GitHub tag/branch of DMD to generate a release for.

        Your temp dir is:
        ` ~ defaultWorkDir ~ `

        Options:
        --help             Display this message and exit.
        -q,--quiet         Quiet mode.
        -v,--verbose       Verbose mode.

        --extras=path      Include additional files from 'path'. The path should be a
                           directory tree matching the DMD release structure (including
                           the 'dmd2' dir). All files in 'path' will be included in
                           the release. This is required, in order to include all
                           the DM bins/libs that are not on GitHub.

        --skip-clone       Instead of cloning DMD repos from GitHub, use
                           already-existing clones. Useful if you've already run
                           create_release and don't want to repeat the cloning process.
                           The repositories will NOT be switched to TAG_OR_BRANCH,
                           TAG_OR_BRANCH will ONLY be used for directory/archive names.
                           Default path is the temp dir (see above).

        --use-clone=path   Instead of cloning DMD repos from GitHub, use the existing
                           clones in the given path. Implies --skip-clone.
                           Use with caution! There's no guarantee the result will
                           be consistent with GitHub!

        --skip-build       Don't build DMD, assume all tools/libs are already built.
                           Implies --skip-clone. Can be used with --use-clone=path.

        --skip-package     Don't create release directory, assume it has already been
                           created. Useful together with the --archive option.
                           Implies --skip-build.

        --archive          Create platform-specific zip archive.

        --clean            Delete temporary dir (see above) and exit.

        --only-32          Only build and package 32-bit.
        --only-64          Only build and package 64-bit.

        On OSX, --only-32 and --only-64 are not recommended because universal
        binaries will NOT be created.
        `).outdent().strip()
    );
}

bool quiet;
bool verbose;
bool skipClone;
bool skipBuild;
bool skipPackage;
bool skipDocs;
bool doArchive;
bool do32Bit;
bool do64Bit;

version(Windows)
{
    string msvcBinDir;
}

// These are absolute and do NOT contain a trailing slash:
string defaultWorkDir;
string cloneDir;
string origDir;
string releaseDir;
string releaseBin32Dir;
string releaseLib32Dir;
string releaseBin64Dir;
string releaseLib64Dir;
string osDir;
string allExtrasDir;
string osExtrasDir;
string customExtrasDir;
string win64vcDir;
string win64sdkDir;

int main(string[] args)
{
    defaultWorkDir = buildPath(tempDir(), defaultWorkDirName);

    bool help;
    bool clean;

    try
    {
        getopt(
            args,
            std.getopt.config.caseSensitive,
            "help",         &help,
            "q|quiet",      &quiet,
            "v|verbose",    &verbose,
            "skip-clone",   &skipClone,
            "use-clone",    &cloneDir,
            "skip-build",   &skipBuild,
            "skip-docs",    &skipDocs,
            "skip-package", &skipPackage,
            "clean",        &clean,
            "extras",       &customExtrasDir,
            "archive",      &doArchive,
            "only-32",      &do32Bit,
            "only-64",      &do64Bit,
        );
    }
    catch(Exception e)
    {
        if(isUnrecognizedOptionException(e))
        {
            errorMsg(e.msg ~ "\nRun with --help to see options.");
            return 1;
        }

        throw e;
    }

    if(args.length < 2)
    {
        errorMsg("Missing arguments.");
        showHelp();
        return 1;
    }

    // Handle command line args
    if(help)
    {
        showHelp();
        return 0;
    }

    if(args.length != 2 && !clean)
    {
        errorMsg("Missing TAG_OR_BRANCH.\nSee --help for more info.");
        return 1;
    }

    if(quiet && verbose)
    {
        errorMsg("Can't use both --quiet and --verbose");
        return 1;
    }

    if(do32Bit && do64Bit)
    {
        errorMsg("--only-32 and --only-64 cannot be used together.");
        return 1;
    }

    version(OSX)
    {
        if(do32Bit || do64Bit)
        {
            infoMsg("WARNING: Using --only-32 and --only-64: Universal binaries will not be created.");
            return 1;
        }
    }

    if(!do32Bit && !do64Bit)
        do32Bit = do64Bit = true;

    if(skipPackage)
        skipBuild = true;

    if(cloneDir != "" || skipBuild)
        skipClone = true;

    if(skipPackage && !doArchive)
    {
        errorMsg("Nothing to do! Specified --skip-package, but not --archive.");
        return 1;
    }

    if(customExtrasDir == "")
    {
        errorMsg("--extras=path is required.\nSee --help for more info.");
        return 1;
    }
    else
        customExtrasDir = customExtrasDir.absolutePath().chomp("\\").chomp("/");

    // Do the work
    try
    {
        if(clean)
        {
            removeDir(defaultWorkDir);
            return 0;
        }

        if(customExtrasDir != "")
            ensureDir(customExtrasDir);

        string branch = args[1];
        init(branch);

        if(!skipClone)
        {
            ensureNotFile(cloneDir);
            removeDir(cloneDir);
            makeDir(cloneDir);
        }

        if(!skipClone)
            cloneSources(branch);

        // No need for the cloned repos if we're not generating
        // the release directory.
        if(!skipPackage)
            ensureSources();

        // No need to clean if we just cloned, or if we're not building.
        if(skipClone && !skipBuild)
            cleanAll(branch);

        if(!skipBuild)
            buildAll(branch);

        if(!skipPackage)
            createRelease(branch);

        if(doArchive)
            createZip(branch);

        infoMsg("Done!");
    }
    catch(Fail e)
    {
        // Just show the message, omit the stack trace.
        errorMsg(e.msg);
        return 1;
    }

    return 0;
}

void init(string branch)
{
    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);

    // Setup directory paths
    origDir = getcwd();
    auto dirBitSuffix = releaseBitSuffix(do32Bit, do64Bit);
    releaseDir = origDir ~ `/dmd.` ~ branch ~ "." ~ osDirName ~ dirBitSuffix;

    if(cloneDir == "")
        cloneDir = defaultWorkDir;
    cloneDir = absolutePath(cloneDir);

    osDir = releaseDir ~ "/dmd2/" ~ osDirName;
    releaseBin32Dir = osDir ~ "/bin" ~ suffix32;
    releaseLib32Dir = osDir ~ "/lib" ~ suffix32;
    releaseBin64Dir = osDir ~ "/bin" ~ suffix64;
    releaseLib64Dir = osDir ~ "/lib" ~ suffix64;
    allExtrasDir = cloneDir ~ "/installer/create_dmd_release/extras/all";
    osExtrasDir  = cloneDir ~ "/installer/create_dmd_release/extras/" ~ osDirName;

    // Check for required external tools
    if(!skipClone)
        ensureTool("git");

    // Check for DMC and MSVC toolchains
    version(Windows)
    {
        // Small workaround because DMC/MAKE's help screens don't return exit code 0
        enum dummyFile  = ".create_release_dummy";
        std.file.write(dummyFile, "");
        scope(exit) removeFile(dummyFile);

        ensureTool("dmc", "-c "~dummyFile);
        ensureTool(make, "-f "~dummyFile);

        // Check DMC's OPTLINK (not just any OPTLINK on the PATH)
        enum dummyCFile = ".create_release_dummy.c";
        std.file.write(dummyCFile, "void main(){}");
        scope(exit) removeFile(dummyCFile);

        enum dummyOptlinkHelp = ".create_release_optlink_help";
        run("dmc "~dummyCFile~" -L/? > "~dummyOptlinkHelp);
        scope(exit) removeFile(dummyOptlinkHelp);

        if(!checkTool("type", dummyOptlinkHelp, `OPTLINK \(R\) for Win32`))
            fail("DMC appears to be missing OPTLINK");

        // Check support files needed during build
        auto extrasOptlink = customExtrasDir~"/dmd2/windows/bin/link.exe";
        if(!checkTool(extrasOptlink, "/?", `OPTLINK \(R\) for Win32`))
            fail("You must have a valid OPTLINK in: "~displayPath(extrasOptlink));

        if(!checkTool(extrasOptlink, "/?", `OPTLINK \(R\) for Win32.*LA\[RGEADDRESSAWARE\]`))
        {
            fail("The OPTLINK in your --extras=... directory does not support "~
                "/LARGEADDRESSAWARE. You must use a newer OPTLINK. "~
                "See <http://wiki.dlang.org/Building_OPTLINK>");
        }

        ensureFile(customExtrasDir~"/dmd2/windows/lib/user32.lib");
        ensureFile(customExtrasDir~"/dmd2/windows/lib/kernel32.lib");
        ensureFile(customExtrasDir~"/dmd2/windows/lib/snn.lib");
        ensureFile(customExtrasDir~"/dmd2/windows/lib/ws2_32.lib");
        ensureFile(customExtrasDir~"/dmd2/windows/lib/wsock32.lib");
        ensureFile(customExtrasDir~"/dmd2/windows/lib/shell32.lib");
        ensureFile(customExtrasDir~"/dmd2/windows/lib/advapi32.lib");

        // Check MSVC tools needed for 64-bit
        if(do64Bit)
        {
            if(environment.get("VCDIR", "") == "" || environment.get("SDKDIR", "") == "")
            {
                fail(`
                    Environment variables VCDIR and SDKDIR must both be set. For example:
                    set VCDIR=C:\Program Files (x86)\Microsoft Visual Studio 8\VC\
                    set SDKDIR=C:\Program Files\Microsoft SDKs\Windows\v7.1\
                `.outdent().strip());
            }

            win64vcDir  = environment[ "VCDIR"].chomp("\\").chomp("/");
            win64sdkDir = environment["SDKDIR"].chomp("\\").chomp("/");

            verboseMsg("VCDIR:  " ~ displayPath(win64vcDir));
            verboseMsg("SDKDIR: " ~ displayPath(win64sdkDir));

            msvcBinDir = win64vcDir ~ "/bin/x86_amd64";
            if(!exists(msvcBinDir~"cl.exe"))
                msvcBinDir = win64vcDir ~ "/bin/amd64";

            ensureTool(quote(msvcBinDir~"/cl.exe"), "/HELP");
            try
            {
                ensureDir(win64sdkDir);
                ensureDir(win64sdkDir~"/Bin");
                ensureDir(win64sdkDir~"/Include");
                ensureDir(win64sdkDir~"/Lib");
            }
            catch(Fail e)
                fail("SDKDIR doesn't appear to be a proper Windows SDK: " ~ environment["SDKDIR"]);
        }
    }
    else
        // Check for GNU make
        ensureTool(make);
}

void cloneSources(string branch)
{
    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);
    changeDir(cloneDir);

    auto prefix = "https://github.com/D-Programming-Language/";
    gitClone(prefix~"dmd.git", "dmd", branch);
    gitClone(prefix~"druntime.git",  "druntime",  branch);
    gitClone(prefix~"phobos.git",    "phobos",    branch);
    gitClone(prefix~"tools.git",     "tools",     branch);
    gitClone(prefix~"dlang.org.git", "dlang.org", branch);
    gitClone(prefix~"installer.git", "installer", branch);
}

void ensureSources()
{
    ensureDir(cloneDir);
    ensureDir(cloneDir~"/dmd");
    ensureDir(cloneDir~"/druntime");
    ensureDir(cloneDir~"/phobos");
    ensureDir(cloneDir~"/tools");
    ensureDir(cloneDir~"/dlang.org");
    ensureDir(cloneDir~"/installer");
}

void cleanAll(string branch)
{
    if(do32Bit)
        cleanAll(Bits.bits32, branch);

    if(do64Bit)
        cleanAll(Bits.bits64, branch);
}

void cleanAll(Bits bits, string branch)
{
    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);

    auto targetMakefile = bits == Bits.bits32? makefile : makefile64;
    auto bitsStr        = bits == Bits.bits32? "32" : "64";
    auto bitsDisplay = toString(bits);
    auto makeModel = " MODEL="~bitsStr;
    auto latest = " LATEST="~branch;
    auto hideStdout = verbose? "" : " > "~devNull;

    // common make arguments
    auto makecmd = make~makeModel~latest~" -f"~targetMakefile;

    // Windows is 32-bit only currently
    if (targetMakefile != "win64.mak")
    {
        infoMsg("Cleaning DMD "~bitsDisplay);
        changeDir(cloneDir~"/dmd/src");
        run(makecmd~" clean"~hideStdout);
    }

    infoMsg("Cleaning Druntime "~bitsDisplay);
    changeDir(cloneDir~"/druntime");
    run(makecmd~" clean"~hideStdout);

    infoMsg("Cleaning Phobos "~bitsDisplay);
    changeDir(cloneDir~"/phobos");
    run(makecmd~" clean DOCSRC=../dlang.org DOC=doc"~hideStdout);
    version(Windows)
        removeDir(cloneDir~"/phobos/generated");

    // Windows is 32-bit only currently
    if (targetMakefile != "win64.mak")
    {
        infoMsg("Cleaning Tools "~bitsDisplay);
        changeDir(cloneDir~"/tools");
        run(makecmd~" clean"~hideStdout);
    }

    // Docs are bits-independent, so treat them as 32-bit only
    if(bits == Bits.bits32)
    {
        infoMsg("Cleaning dlang.org");
        changeDir(cloneDir~"/dlang.org");
        run(makecmd~" clean"~hideStdout);
    }
}

void buildAll(string branch)
{
    if(do32Bit)
        buildAll(Bits.bits32, branch);

    if(do64Bit)
    {
        if(!do32Bit && lib64RequiresDmd32)
            buildAll(Bits.bits32, branch, true);

        buildAll(Bits.bits64, branch);
    }
}

/// dmdOnly is part of the lib64RequiresDmd32 hack.
void buildAll(Bits bits, string branch, bool dmdOnly=false)
{
    static alreadyBuiltDocs = false;

    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);

    auto msvcEnv = "";
    version(Windows)
    {
        if(bits == Bits.bits64)
        {
            msvcEnv =
                " VCDIR="  ~ quote(win64vcDir) ~
                " SDKDIR=" ~ quote(win64sdkDir) ~
                " CC="     ~ quote(`\"` ~ msvcBinDir~"/cl"   ~`\"`) ~
                " LD="     ~ quote(`\"` ~ msvcBinDir~"/link" ~`\"`) ~
                " AR="     ~ quote(`\"` ~ msvcBinDir~"/lib"  ~`\"`);
            }
    }

    auto targetMakefile = bits == Bits.bits32? makefile    : makefile64;
    auto libPhobos      = bits == Bits.bits32? libPhobos32 : libPhobos64;
    auto bitsStr = bits == Bits.bits32? "32" : "64";
    auto bitsDisplay = toString(bits);
    auto makeModel = " MODEL="~bitsStr;
    auto hideStdout = verbose? "" : " > "~devNull;
    version (Windows)
    {
        auto jobs = "";
        auto dmdEnv = ` DMD=..\dmd\src\dmd`;
    }
    else
    {
        auto jobs = " -j4";
        auto dmdEnv = " DMD=../dmd/src/dmd";
    }
    auto isRelease = " RELEASE=1";
    auto latest = " LATEST="~branch;

    // common make arguments
    auto makecmd = make~jobs~makeModel~dmdEnv~isRelease~latest~" -f "~targetMakefile;

    if(build64BitTools || bits == Bits.bits32)
    {
        infoMsg("Building DMD "~bitsDisplay);
        changeDir(cloneDir~"/dmd/src");
        run(makecmd~" dmd"~hideStdout);
        copyFile(cloneDir~"/dmd/src/dmd"~exe, cloneDir~"/dmd/src/dmd"~bitsStr~exe);
        removeFiles(cloneDir~"/dmd/src", "*{"~obj~","~lib~"}", SpanMode.depth);
    }

    // Generate temporary sc.ini/dmd.conf
    version(Windows)
    {
        std.file.write(cloneDir~"/dmd/src/sc.ini", (`
            [Environment]
            LIB="%@P%\..\..\phobos" "`~customExtrasDir~`\dmd2\windows\lib" "%@P%\..\..\installer\create_dmd_release\extras\windows\dmd2\windows\lib"
            DFLAGS="-I%@P%\..\..\phobos" "-I%@P%\..\..\druntime\import"
        `).outdent().strip());
    }
    else version(Posix)
    {
        version(OSX)
            enum flags="";
        else
            enum flags=" -L--export-dynamic";

        std.file.write(cloneDir~"/dmd/src/dmd.conf", (`
            [Environment]
            DFLAGS=-I%@P%/../../phobos -I%@P%/../../druntime/src -L-L%@P%/../../phobos/generated/`~osDirName~`/release/`~bitsStr~` -L-L%@P%/../../druntime/lib`~flags~`
        `).outdent().strip());
    }
    else
        static assert(false, "Unsupported platform");

    // Copy OPTLINK to same directory as the sc.ini we want it to read
    version(Windows)
        copyFile(customExtrasDir~"/dmd2/windows/bin/link.exe", cloneDir~"/dmd/src/link.exe");

    if(dmdOnly)
        return;

    infoMsg("Building Druntime "~bitsDisplay);
    changeDir(cloneDir~"/druntime");
    run(makecmd~msvcEnv~hideStdout);
    removeFiles(cloneDir~"/druntime", "*{"~obj~"}", SpanMode.depth,
        file => !file.baseName.startsWith("gcstub", "minit"));

    infoMsg("Building Phobos "~bitsDisplay);
    changeDir(cloneDir~"/phobos");
    run(makecmd~msvcEnv~hideStdout);

    version(OSX)
    {
        if(bits == Bits.bits64)
        {
            infoMsg("Building Phobos Universal Binary");
            changeDir(cloneDir~"/phobos");
            run(makecmd~" libphobos2.a"~hideStdout);
        }
    }

    version(Windows)
    {
        makeDir(cloneDir~"/phobos/generated/windows/release/"~bitsStr);
        copyFile(
            cloneDir~"/phobos/"~libPhobos~lib,
            cloneDir~"/phobos/generated/windows/release/"~bitsStr~"/"~libPhobos~lib
        );
    }
    removeFiles(cloneDir~"/phobos", "*{"~obj~"}", SpanMode.depth);

    // Build docs
    if(!alreadyBuiltDocs && !skipDocs)
    {
        infoMsg("Building Druntime Docs");
        changeDir(cloneDir~"/druntime");

        run(makecmd~" doc DOCSRC=../dlang.org DOCDIR=../web/phobos-prerelease"~hideStdout);

        infoMsg("Building Phobos Docs");
        changeDir(cloneDir~"/phobos");
        run(makecmd~" html DOCSRC=../dlang.org DOC=../web/phobos-prerelease"~hideStdout);

        infoMsg("Building dlang.org");
        version(Posix)
        {
            // Backwards compatability with older versions of the makefile
            auto oldDirName = cloneDir~"/d-programming-language.org";
            if(!exists(oldDirName))
                symlink(cloneDir~"/dlang.org", oldDirName);
        }
        changeDir(cloneDir~"/dlang.org");
        makeDir("doc");
        version(Posix)
            auto dlangOrgTarget = " html";
        else version(Windows)
            auto dlangOrgTarget = "";
        else
            static assert(false, "Unsupported platform");
        // Use 32-bit version of the makefile because dlang.org lacks a win64.mak
        run(makecmd~dlangOrgTarget~hideStdout);
        version(Windows)
        {
            copyDir(cloneDir~"/web/phobos-prerelease", cloneDir~"/dlang.org/phobos");

            // The chm stuff is Win32-only
            if(bits == Bits.bits32)
                run(makecmd~" chm DOCSRC=../dlang.org DOCDIR=../web/phobos-prerelease"~hideStdout);
        }

        // Copy phobos docs into dlang.org docs directory, because
        // dman's posix makefile requires it.
        copyDir(cloneDir~"/web/phobos-prerelease", cloneDir~"/"~generatedDocs~"/phobos");

        alreadyBuiltDocs = true;
    }

    if(build64BitTools || bits == Bits.bits32)
    {
        infoMsg("Building Tools "~bitsDisplay);
        changeDir(cloneDir~"/tools");
        run(makecmd~" rdmd"~hideStdout);
        run(makecmd~" ddemangle"~hideStdout);
        run(makecmd~" dustmite"~hideStdout);
        if (!skipDocs) run(makecmd~" dman"~hideStdout);

        removeFiles(cloneDir~"/tools", "*.{"~obj~"}", SpanMode.depth);
    }
}

/// This doesn't use "make install" in order to avoid problems from
/// differences between 'posix.mak' and 'win*.mak'.
void createRelease(string branch)
{
    infoMsg("Generating release directory");

    removeDir(releaseDir);

    // Copy extras, if any
    if(customExtrasDir != "")
        copyDir(customExtrasDir, releaseDir);

    if(exists(allExtrasDir)) copyDir(allExtrasDir, releaseDir);
    if(exists( osExtrasDir)) copyDir( osExtrasDir, releaseDir);

    // Copy sources (should cppunit be omitted??)
    copyDirVersioned(cloneDir~"/dmd/src",  releaseDir~"/dmd2/src/dmd");
    copyDirVersioned(cloneDir~"/dmd/ini",  releaseDir~"/dmd2");
    copyDirVersioned(cloneDir~"/druntime", releaseDir~"/dmd2/src/druntime");
    copyDirVersioned(cloneDir~"/phobos",   releaseDir~"/dmd2/src/phobos");

    // druntime/doc doesn't get generated on Windows with --only-64, I don't know why.
    if(exists(cloneDir~"/druntime/doc"))
        copyDir(cloneDir~"/druntime/doc", releaseDir~"/dmd2/src/druntime/doc");
    copyDir(cloneDir~"/druntime/import", releaseDir~"/dmd2/src/druntime/import");
    copyFile(cloneDir~"/dmd/VERSION",    releaseDir~"/dmd2/src/VERSION");

    // Copy documentation
    if (!skipDocs)
    {
        auto dlangFilter = (string a) =>
            !a.startsWith("images/original/") &&
            !a.startsWith("chm/") &&
            ( a.endsWith(".html") || a.startsWith("css/", "images/", "js/") );
        copyDir(cloneDir~"/"~generatedDocs, releaseDir~"/dmd2/html/d", a => dlangFilter(a));
        version(Windows)
        {
            if(do32Bit)
                copyFile(cloneDir~"/"~generatedDocs~"/d.chm", releaseBin32Dir~"/d.chm");
        }
        copyDirVersioned(cloneDir~"/dmd/samples",  releaseDir~"/dmd2/samples/d");
        copyDirVersioned(cloneDir~"/dmd/docs/man", releaseDir~"/dmd2/man");
        copyDirVersioned(cloneDir~"/tools/man", releaseDir~"/dmd2/man");
        makeDir(releaseDir~"/dmd2/html/d/zlib");
        copyFile(cloneDir~"/phobos/etc/c/zlib/ChangeLog", releaseDir~"/dmd2/html/d/zlib/ChangeLog");
        copyFile(cloneDir~"/phobos/etc/c/zlib/README",    releaseDir~"/dmd2/html/d/zlib/README");
        copyFile(cloneDir~"/phobos/etc/c/zlib/zlib.3",    releaseDir~"/dmd2/html/d/zlib/zlib.3");
    }

    // Copy lib
    version(OSX)
    {
        if(do32Bit && do64Bit)
            copyFile(cloneDir~"/phobos/generated/"~osDirName~"/release/libphobos2.a", releaseLib32Dir~"/libphobos2.a");
        else if(do32Bit)
            copyFile(cloneDir~"/phobos/generated/"~osDirName~"/release/32/libphobos2.a", releaseLib32Dir~"/libphobos2_32.a");
        else if(do64Bit)
            copyFile(cloneDir~"/phobos/generated/"~osDirName~"/release/64/libphobos2.a", releaseLib32Dir~"/libphobos2_64.a");
    }
    else
    {
        if(do32Bit)
        {
            copyFile(cloneDir~"/phobos/generated/"~osDirName~"/release/32/"~libPhobos32~lib, releaseLib32Dir~"/"~libPhobos32~lib);
            copyFileIfExists(cloneDir~"/phobos/generated/"~osDirName~"/release/32/"~libPhobos32~dll, releaseLib32Dir~"/"~libPhobos32~dll);
            version (Windows)
                copyFile(cloneDir~"/druntime/lib/gcstub.obj", releaseLib32Dir~"/gcstub.obj");
        }
        if(do64Bit)
        {
            copyFile(cloneDir~"/phobos/generated/"~osDirName~"/release/64/"~libPhobos64~lib, releaseLib64Dir~"/"~libPhobos64~lib);
            copyFileIfExists(cloneDir~"/phobos/generated/"~osDirName~"/release/64/"~libPhobos64~dll, releaseLib64Dir~"/"~libPhobos64~dll);
            version (Windows)
                copyFile(cloneDir~"/druntime/lib/gcstub64.obj", releaseLib64Dir~"/gcstub64.obj");
        }
    }

    // Copy bin32
    version(OSX) {} else // OSX doesn't include 32-bit tools
    {
        if(do32Bit)
        {
            copyFile(cloneDir~"/dmd/src/dmd32"~exe, releaseBin32Dir~"/dmd"~exe);
            copyDir(cloneDir~"/tools/generated/"~osDirName~"/32", releaseBin32Dir, file => !file.endsWith(obj));
        }
    }

    // Copy bin64
    version(Windows) {} else // Win doesn't include 64-bit tools
    {
        if(do64Bit)
        {
            copyFile(cloneDir~"/dmd/src/dmd64"~exe, releaseBin64Dir~"/dmd"~exe);
            copyDir(cloneDir~"/tools/generated/"~osDirName~"/64", releaseBin64Dir, file => !file.endsWith(obj));
        }
    }

    verifyExtras();
}

void verifyExtras()
{
    infoMsg("Ensuring non-versioned support files exist");

    version(Windows)
    {
        auto files = [
            releaseBin32Dir~"/lib.exe",
            releaseBin32Dir~"/link.exe",
            releaseBin32Dir~"/make.exe",
            releaseBin32Dir~"/replace.exe",
            releaseBin32Dir~"/shell.exe",
            releaseBin32Dir~"/windbg.exe",
            releaseBin32Dir~"/dm.dll",
            releaseBin32Dir~"/eecxxx86.dll",
            releaseBin32Dir~"/emx86.dll",
            releaseBin32Dir~"/mspdb41.dll",
            releaseBin32Dir~"/shcv.dll",
            releaseBin32Dir~"/tlloc.dll",

            releaseLib32Dir~"/advapi32.lib",
            releaseLib32Dir~"/COMCTL32.lib",
            releaseLib32Dir~"/comdlg32.lib",
            releaseLib32Dir~"/CTL3D32.lib",
            releaseLib32Dir~"/gdi32.lib",
            releaseLib32Dir~"/kernel32.lib",
            releaseLib32Dir~"/ODBC32.lib",
            releaseLib32Dir~"/ole32.lib",
            releaseLib32Dir~"/OLEAUT32.lib",
            releaseLib32Dir~"/rpcrt4.lib",
            releaseLib32Dir~"/shell32.lib",
            releaseLib32Dir~"/snn.lib",
            releaseLib32Dir~"/user32.lib",
            releaseLib32Dir~"/uuid.lib",
            releaseLib32Dir~"/winmm.lib",
            releaseLib32Dir~"/winspool.lib",
            releaseLib32Dir~"/WS2_32.lib",
            releaseLib32Dir~"/wsock32.lib",
        ];
    }
    else version(linux)
    {
        auto files = [
            releaseBin32Dir~"/dumpobj",
            releaseBin32Dir~"/obj2asm",

            releaseBin64Dir~"/dumpobj",
            releaseBin64Dir~"/obj2asm",
        ];
    }
    else version(OSX)
    {
        auto files = [
            releaseBin32Dir~"/dumpobj",
            releaseBin32Dir~"/obj2asm",
            releaseBin32Dir~"/shell",
        ];
    }
    else version(FreeBSD)
    {
        auto files = [
            releaseBin32Dir~"/dumpobj",
            releaseBin32Dir~"/obj2asm",
            releaseBin32Dir~"/shell",
        ];
    }
    else
        string[] files;


    bool filesMissing = false;
    foreach(file; files)
    {
        if(!exists(file) || !isFile(file))
        {
            if(!filesMissing)
            {
                errorMsg("The following files are missing:");
                filesMissing = true;
            }

            stderr.writeln(displayPath(file));
        }
    }

    if(filesMissing)
    {
        fail(
            "The above files were missing from the appropriate dirs:\n"~
            displayPath(customExtrasDir ~ releaseBin32Dir.chompPrefix(releaseDir))~"\n"~
            displayPath(customExtrasDir ~ releaseLib32Dir.chompPrefix(releaseDir))~"\n"~
            displayPath(customExtrasDir ~ releaseBin64Dir.chompPrefix(releaseDir))~"\n"~
            displayPath(customExtrasDir ~ releaseLib64Dir.chompPrefix(releaseDir))
        );
    }
}

void createZip(string branch)
{
    auto archiveName = baseName(releaseDir)~".zip";
    archiveZip(releaseDir~"/dmd2", archiveName);
}

// Utils -----------------------

void verboseMsg(lazy string msg)
{
    if(verbose)
        infoMsg(msg);
}

void infoMsg(lazy string msg)
{
    if(!quiet)
        writeln(msg);
}

void errorMsg(string msg)
{
    stderr.writeln("create_dmd_release: Error: "~msg);
}

/// Ugly hack around the lack of an UnrecognizedOptionException
bool isUnrecognizedOptionException(Exception e)
{
    return e && e.msg.startsWith("Unrecognized option");
}

// Test assumptions made by isUnrecognizedOptionException
unittest
{
    bool bar;
    auto args = ["someapp", "--foo"];
    auto e = collectException!Exception(getopt(args, "bar", &bar));
    assert(
        isUnrecognizedOptionException(e),
        "getopt's behavior upon unrecognized options is not as expected"
    );
}

/// Cleanup a path for display to the user:
/// - Strip current directory prefix, if applicable. (ie, The current directory
///   from the user's perspective, not this program's internal current directory.)
/// - On windows: Convert slashes to backslash.
string displayPath(string path)
{
    version(Windows)
        path = path.replace("/", "\\");

    return chompPrefix(path, origDir ~ dirSeparator);
}

string quote(string str)
{
    version(Windows)
        return `"`~str~`"`;
    else
        return `'`~str~`'`;
}

string releaseBitSuffix(bool has32, bool has64)
{
    if(do32Bit && !do64Bit)
        return releaseBitSuffix32;

    if(do64Bit && !do32Bit)
        return releaseBitSuffix64;

    return "";
}

// Filesystem Utils -----------------------

void ensureNotFile(string path)
{
    if(exists(path) && !isDir(path))
        fail("'"~path~"' is a file, not a directory");
}

void ensureFile(string path)
{
    if(!exists(path) || !isFile(path))
        fail("Missing file: "~path);
}

void ensureDir(string path)
{
    if(!exists(path) || !isDir(path))
        fail("Directory not found: "~path);
}

/// Removes a file if it exists, otherwise do nothing
void removeFile(string path)
{
    if(exists(path))
        std.file.remove(path);
}

void removeFiles(string path, string pattern, SpanMode mode,
    bool delegate(string) filter)
{
    removeFiles(path, pattern, mode, true, filter);
}

void removeFiles(string path, string pattern, SpanMode mode,
    bool followSymlink = true, bool delegate(string) filter = null)
{
    if(mode == SpanMode.breadth)
        throw new Exception("removeFiles can only take SpanMode of 'depth' or 'shallow'");

    auto displaySuffix = mode==SpanMode.shallow? "" : "/*";
    verboseMsg("Deleting '"~pattern~"' from '"~displayPath(path~displaySuffix)~"'");

    // Needed to generate 'relativePath' correctly.
    path = path.replace("\\", "/");
    if(!path.endsWith("/", "\\"))
        path ~= "/";

    foreach(DirEntry entry; dirEntries(path[0..$-1], pattern, mode, false))
    {
        if(entry.isFile)
        {
            auto relativePath = entry.replace("\\", "/").chompPrefix(path);

            if(!filter || filter(relativePath))
            {
                verboseMsg("    " ~ displayPath(relativePath));
                entry.remove();
            }
            else if(filter)
                verboseMsg("    Skipping: " ~ displayPath(relativePath));
        }
    }
}

/// Remove entire directory tree. If it doesn't exist, do nothing.
void removeDir(string path)
{
    if(exists(path))
    {
        verboseMsg("Removing dir: "~displayPath(path));

        void removeDirFailed()
        {
            fail(
                "Failed to remove directory: "~displayPath(path)~"\n"~
                "    A process may still holding an open handle within the directory.\n"~
                "    Either delete the directory manually or try again later."
            );
        }

        try
        {
            version(Windows)
                system("rmdir /S /Q "~quote(path));
            else
                system("rm -rf "~quote(path));
        }
        catch(Exception e)
            removeDirFailed();

        if(exists(path))
            removeDirFailed();
    }
}

/// Like mkdirRecurse, but no error if directory already exists.
void makeDir(string path)
{
    if(!exists(path))
    {
        verboseMsg("Creating dir: "~displayPath(path));
        mkdirRecurse(path);
    }
}

void changeDir(string path)
{
    verboseMsg("Entering dir: "~displayPath(path));

    try
        chdir(path);
    catch(FileException e)
        fail(e.msg);
}

/// Copy file attributes from src file to dest file
/// Does nothing on non-Posix
void copyAttributes(string src, string dest)
{
    // Only needed on Posix
    version(Posix)
    {
        auto attr = cast(mode_t)getAttributes(src);
        auto result = chmod(dest.toStringz(), attr);
        if(result != 0)
            fail("Unable to set attributes on: " ~ dest);
    }
}

/// Recursively copy the contents of a directory, excluding anything
/// untracked or ignored by git.
void copyDirVersioned(string src, string dest, bool delegate(string) filter = null)
{
    auto versionedFiles = gitVersionedFiles(src);
    copyFiles(versionedFiles, src, dest, filter);
}

/// Recursively copy contents of 'src' directory into 'dest' directory.
/// Directory 'dest' will be created if it doesn't exist.
/// Takes optional delegate to filter out any files to not copy.
void copyDir(string src, string dest, bool delegate(string) filter = null)
{
    verboseMsg("Copying from '"~displayPath(src)~"' to '"~displayPath(dest)~"'");

    // Needed to generate 'relativePath' correctly.
    src = src.replace("\\", "/");
    if(!src.endsWith("/", "\\"))
        src ~= "/";

    ensureDir(src);
    makeDir(dest);
    foreach(DirEntry entry; dirEntries(src[0..$-1], SpanMode.breadth, false))
    {
        auto relativePath = entry.name.replace("\\", "/").chompPrefix(src);

        if (relativePath.baseName.startsWith(".") ||
            filter !is null && !filter(relativePath))
        {
            verboseMsg("    Skipping: " ~ displayPath(relativePath));
            continue;
        }

        verboseMsg("    " ~ displayPath(relativePath));

        auto destPath = buildPath(dest, relativePath);
        auto srcPath  = buildPath(src,  relativePath);

        version(Posix)
        {
            if(entry.isSymlink)
            {
                run("cp -P "~srcPath~" "~destPath);
                continue;
            }
        }

        if(entry.isDir)
            makeDir(destPath);
        else
        {
            makeDir(dirName(destPath));
            copy(srcPath, destPath);
            copyAttributes(srcPath, destPath);
        }
    }
}

// External Tools -----------------------

/// Check if running "tool --help" succeeds. If not, returns false.
bool checkTool(string cmd, string cmdArgs="--help", string regexMatch=null)
{
    auto cmdLine = cmd~" "~cmdArgs;
    verboseMsg("Checking: "~cmdLine);

    try
    {
        auto result = shell(cmdLine~" 2> "~devNull);
        if(regexMatch != "" && !match(result, regex(regexMatch, "s")))
            return false;
    }
    catch(Exception e)
        return false;

    return true;
}

/// Check if running "tool --help" succeeds. If not, throws Fail.
void ensureTool(string cmd, string cmdArgs="--help", string regexMatch=null)
{
    if(!checkTool(cmd, cmdArgs, regexMatch))
        fail("Problem running '"~cmd~"'. Please make sure it's correctly installed.");
}

/// Like system(), but throws useful Fail message upon failure.
void run(string cmd)
{
    verboseMsg("Running: "~cmd);

    stdout.flush();
    stderr.flush();

    auto errlevel = system(cmd);
    if(errlevel != 0)
        fail("Command failed (ran from dir '"~displayPath(getcwd())~"'): "~cmd);
}

/// Like run(), but captures the standard output and returns it.
string runCapture(string cmd)
{
    verboseMsg("Running: "~cmd);

    stdout.flush();
    stderr.flush();

    auto result = executeShell(cmd);
    if(result.status != 0)
        fail("Command failed (ran from dir '"~displayPath(getcwd())~"'): "~cmd);

    return result.output;
}

/// Clone a git repository to a specific path. Optionally to a
/// specific branch (default is master).
///
/// Requires a command-line git client.
void gitClone(string repo, string path, string branch=null)
{
    removeDir(path);
    makeDir(path);

    infoMsg("Cloning: "~repo);
    auto quietSwitch = verbose? "" : "-q ";
    if(branch != "")
        run("git clone --depth 1 -b "~quote(branch)~" "~quietSwitch~quote(repo)~" "~path);
    else
        run("git clone --depth 1 "~quietSwitch~quote(repo)~" "~path);
}

string[] gitVersionedFiles(string path)
{
    auto saveDir = getcwd();
    scope(exit) changeDir(saveDir);
    changeDir(path);

    Appender!(string[]) versionedFiles;
    auto gitOutput = runCapture("git ls-files").strip();
    foreach(filename; gitOutput.splitter("\n"))
        versionedFiles.put(filename);

    return versionedFiles.data;
}
