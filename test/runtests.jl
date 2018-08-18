using BinaryProvider
using BinaryBuilder
using BinaryBuilder: preferred_runner
using Random, LibGit2, Libdl, Test, ObjectFile, SHA

# The platform we're running on
const platform = platform_key()

# On windows, the `.exe` extension is very important
const exe_ext = Sys.iswindows() ? ".exe" : ""

# We are going to build/install libfoo a lot, so here's our function to make sure the
# library is working properly
function check_foo(fooifier_path = "fooifier$(exe_ext)",
                   libfoo_path = "libfoo.$(Libdl.dlext)")
    # We know that foo(a, b) returns 2*a^2 - b
    result = 2*2.2^2 - 1.1

    # Test that we can invoke fooifier
    @test !success(`$fooifier_path`)
    @test success(`$fooifier_path 1.5 2.0`)
    @test parse(Float64,readchomp(`$fooifier_path 2.2 1.1`)) ≈ result

    # Test that we can dlopen() libfoo and invoke it directly
    libfoo = Libdl.dlopen_e(libfoo_path)
    @test libfoo != C_NULL
    foo = Libdl.dlsym_e(libfoo, :foo)
    @test foo != C_NULL
    @test ccall(foo, Cdouble, (Cdouble, Cdouble), 2.2, 1.1) ≈ result
    Libdl.dlclose(libfoo)
end

@testset "File Collection" begin
    temp_prefix() do prefix
        # Create a file and a link, ensure that only the one file is returned by collect_files()
        f = joinpath(prefix, "foo")
        f_link = joinpath(prefix, "foo_link")
        touch(f)
        symlink(f, f_link)

        files = collect_files(prefix)
        @test length(files) == 2
        @test f in files
        @test f_link in files

        collapsed_files = collapse_symlinks(files)
        @test length(collapsed_files) == 1
        @test f in collapsed_files
    end
end

@testset "Target properties" begin
    for t in ["i686-linux-gnu", "i686-w64-mingw32", "arm-linux-gnueabihf"]
        @test BinaryBuilder.target_nbits(t) == "32"
    end

    for t in ["x86_64-linux-gnu", "x86_64-w64-mingw32", "aarch64-linux-gnu",
              "powerpc64le-linux-gnu", "x86_64-apple-darwin14"]
        @test BinaryBuilder.target_nbits(t) == "64"
    end

    for t in ["x86_64-linux-gnu", "x86_64-apple-darwin14", "i686-w64-mingw32"]
        @test BinaryBuilder.target_proc_family(t) == "intel"
    end
    for t in ["aarch64-linux-gnu", "arm-linux-gnueabihf"]
        @test BinaryBuilder.target_proc_family(t) == "arm"
    end
    @test BinaryBuilder.target_proc_family("powerpc64le-linux-gnu") == "power"

    for t in ["aarch64-linux-gnu", "x86_64-unknown-freebsd11.1"]
        @test BinaryBuilder.target_dlext(t) == "so"
    end
    @test BinaryBuilder.target_dlext("x86_64-apple-darwin14") == "dylib"
    @test BinaryBuilder.target_dlext("i686-w64-mingw32") == "dll"
end

@testset "UserNS utilities" begin
    # Test that is_ecryptfs works for something we're certain isn't encrypted
    if isdir("/proc")
        isecfs = (false, "/proc/")
        @test BinaryBuilder.is_ecryptfs("/proc"; verbose=true) == isecfs
        @test BinaryBuilder.is_ecryptfs("/proc/"; verbose=true) == isecfs
        @test BinaryBuilder.is_ecryptfs("/proc/not_a_file"; verbose=true) == isecfs
    else
        @test BinaryBuilder.is_ecryptfs("/proc"; verbose=true) == (false, "/proc")
        @test BinaryBuilder.is_ecryptfs("/proc/"; verbose=true) == (false, "/proc/")
        @test BinaryBuilder.is_ecryptfs("/proc/not_a_file"; verbose=true) == (false, "/proc/not_a_file")
    end
end

libfoo_products(prefix) = [
    LibraryProduct(prefix, "libfoo", :libfoo)
    ExecutableProduct(prefix, "fooifier", :fooifier)
]
libfoo_script = """
/usr/bin/make clean
/usr/bin/make install
"""

@testset "Builder Packaging" begin
    # Clear out previous build products
    for f in readdir(@__DIR__)
        if !endswith(f, ".tar.gz") && !endswith(f, ".tar.gz.256")
            continue
        end
        @show "Deleting $(joinpath(@__DIR__, f))"
        rm(joinpath(@__DIR__, f); force=true)
    end

    # Gotta set this guy up beforehand
    tarball_path = nothing
    tarball_hash = nothing

    begin
        build_path = tempname()
        mkpath(build_path)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], platform)
        cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)
            @test build(ur, "foo", libfoo_products(prefix), libfoo_script, platform, prefix)
        end

        # Next, package it up as a .tar.gz file
        tarball_path, tarball_hash = package(prefix, "./libfoo", v"1.0.0"; verbose=true)
        @test isfile(tarball_path)

        # Delete the build path
        rm(build_path, recursive = true)
    end

    # Test that we can inspect the contents of the tarball
    contents = list_tarball_files(tarball_path)
    @test "bin/fooifier" in contents
    @test "lib/libfoo.$(Libdl.dlext)" in contents

    # Install it within a new Prefix
    temp_prefix() do prefix
        # Install the thing
        @test install(tarball_path, tarball_hash; prefix=prefix, verbose=true)

        # Ensure we can use it
        fooifier_path = joinpath(bindir(prefix), "fooifier")
        libfoo_path = joinpath(libdir(prefix), "libfoo.$(Libdl.dlext)")
        check_foo(fooifier_path, libfoo_path)
    end

    rm(tarball_path; force=true)
    rm("$(tarball_path).sha256"; force=true)
end

if lowercase(get(ENV, "BINARYBUILDER_FULL_SHARD_TEST", "false") ) == "true"
    # Perform a sanity test on each and every shard.
    @testset "Shard sanity tests" begin
        for shard_platform in supported_platforms()
            build_path = tempname()
            mkpath(build_path)
            prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], shard_platform)
            cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
                run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

                # Build libfoo, warn if we fail
                @test build(ur, "foo", libfoo_products(prefix), libfoo_script, shard_platform, prefix)
            end

            # Delete the build path
            rm(build_path, recursive = true)
        end
    end
end

@testset "environment and history saving" begin
    build_path = tempname()
    mkpath(build_path)
    prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], platform)
    @test_throws ErrorException build(ur, "foo", libfoo_products(prefix), "MARKER=1\nexit 1", platform, prefix)

    # Ensure that we get a metadir, and that our history and .env files are in there!
    metadir = joinpath(prefix.path, "..", "metadir")
    @test isdir(metadir)

    hist_file = joinpath(metadir, ".bash_history")
    env_file = joinpath(metadir, ".env")
    @test isfile(hist_file)
    @test isfile(env_file)

    # Test that exit 1 is in .bash_history
    @test occursin("\nexit 1\n", read(open(hist_file), String))

    # Test that MARKER=1 is in .env:
    @test occursin("\nMARKER=1\n", read(open(env_file), String))

    # Delete the build path
    rm(build_path, recursive = true)
end

# Testset to make sure we can build_tarballs() from a local directory
@testset "build_tarballs() local directory based" begin
    build_path = tempname()
    local_dir_path = joinpath(build_path, "libfoo")
    mkpath(local_dir_path)

    cd(build_path) do
        # Just like we package up libfoo into a tarball above, we'll just copy it
        # into a new directory and use build_tarball's ability to auto-package
        # local directories to do all the heavy lifting.
        libfoo_dir = joinpath(@__DIR__, "build_tests", "libfoo")
        run(`cp -r $(libfoo_dir)/$(readdir(libfoo_dir)) $local_dir_path`)

        build_tarballs(
            [], # fake ARGS
            "libfoo",
            v"1.0.0",
            [local_dir_path],
            libfoo_script,
            [Linux(:x86_64, :glibc)],
            libfoo_products,
            [], # no dependencies
        )

        # Make sure that worked
        @test isfile("products/libfoo.v1.0.0.x86_64-linux-gnu.tar.gz")
        @test isfile("products/build_libfoo.v1.0.0.jl")
    end
end

# Testset to make sure we can build_tarballs() from a git repository
@testset "build_tarballs() Git-Based" begin
    build_path = tempname()
    git_path = joinpath(build_path, "libfoo.git")
    mkpath(git_path)

    cd(build_path) do
        # Just like we package up libfoo into a tarball above, we'll create a fake
        # git repo for it here, then build from that.
        repo = LibGit2.init(git_path)
        LibGit2.commit(repo, "Initial empty commit")
        libfoo_dir = joinpath(@__DIR__, "build_tests", "libfoo")
        run(`cp -r $(libfoo_dir)/$(readdir(libfoo_dir)) $git_path/`)
        for file in ["fooifier.c", "libfoo.c", "Makefile"]
            LibGit2.add!(repo, file)
        end
        commit = LibGit2.commit(repo, "Add libfoo files")

        # Now build that git repository for Linux x86_64
        sources = [
            git_path =>
            LibGit2.string(LibGit2.GitHash(commit)),
        ]

        build_tarballs(
            [], # fake ARGS
            "libfoo",
            v"1.0.0",
            sources,
            "cd libfoo\n$libfoo_script",
            [Linux(:x86_64, :glibc)],
            libfoo_products,
            [], # no dependencies
        )

        # Make sure that worked
        @test isfile("products/libfoo.v1.0.0.x86_64-linux-gnu.tar.gz")
        @test isfile("products/build_libfoo.v1.0.0.jl")
    end

    rm(build_path; force=true, recursive=true)
end

@testset "build_tarballs() --only-buildjl" begin
    build_path = tempname()
    mkpath(build_path)
    cd(build_path) do
        # Clone down OggBuilder.jl
        repo = LibGit2.clone("https://github.com/staticfloat/OggBuilder", ".")

        # Check out a known-good tag
        LibGit2.checkout!(repo, string(LibGit2.GitHash(LibGit2.GitCommit(repo, "v1.3.3-6"))))

        # Reconstruct binaries!  We don't want it to pick up BinaryBuilder.jl information from CI,
        # so wipe out those environment variables through withenv:
        blacklist = ["CI_REPO_OWNER", "CI_REPO_NAME", "TRAVIS_REPO_SLUG", "TRAVIS_TAG", "CI_COMMIT_TAG"]
        withenv((envvar => nothing for envvar in blacklist)...) do
            m = Module(:__anon__)
            Core.eval(m, quote
                ARGS = ["--only-buildjl"]
            end)
            Base.include(m, joinpath(build_path, "build_tarballs.jl"))
        end

        # Read in `products/build.jl` to get download_info
        m = Module(:__anon__)
        download_info = Core.eval(m, quote
            using BinaryProvider
            # Override BinaryProvider functionality so that it doesn't actually install anything
            function install(args...; kwargs...); end
            function write_deps_file(args...; kwargs...); end
        end)
        # Include build.jl file to extract download_info
        Base.include(m, joinpath(build_path, "products", "build_Ogg.v1.3.3.jl"))
        download_info = Core.eval(m, :(download_info))

        # Test that we get the info right about some of these platforms
        bin_prefix = "https://github.com/staticfloat/OggBuilder/releases/download/v1.3.3-6"
        @test download_info[Linux(:x86_64)] == (
            "$bin_prefix/Ogg.v1.3.3.x86_64-linux-gnu.tar.gz",
            "6ef771242553b96262d57b978358887a056034a3c630835c76062dca8b139ea6",
        )
        @test download_info[Windows(:i686)] == (
            "$bin_prefix/Ogg.v1.3.3.i686-w64-mingw32.tar.gz",
            "3f6f6f524137a178e9df7cb5ea5427de6694c2a44ef78f1491d22bd9c6c8a0e8",
        )
    end
end

@testset "Auditor - ISA tests" begin
    begin
        build_path = tempname()
        mkpath(build_path)
        isa_platform = Linux(:x86_64)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], isa_platform)

        main_sse = ExecutableProduct(prefix, "main_sse", :main_sse)
        main_avx = ExecutableProduct(prefix, "main_avx", :main_avx)
        main_avx2 = ExecutableProduct(prefix, "main_avx2", :main_avx2)
        products = [main_sse, main_avx, main_avx2]

        cd(joinpath(dirname(@__FILE__),"build_tests","isa_tests")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # Build isa tests
            script="""
            /usr/bin/make clean
            /usr/bin/make install
            """

            # Build it
            @test build(ur, "isa_tests", products, script, isa_platform, prefix; verbose=true)

            # Ensure it's satisfied
            @test all(satisfied(r; verbose=true) for r in products)
        end

        # Next, test isa of these files
        readmeta(locate(main_sse)) do oh
            isa_sse = BinaryBuilder.analyze_instruction_set(oh; verbose=true)
            @test isa_sse == :core2
        end

        readmeta(locate(main_avx)) do oh
            isa_avx = BinaryBuilder.analyze_instruction_set(oh; verbose=true)
            @test isa_avx == :sandybridge
        end

        readmeta(locate(main_avx2)) do oh
            isa_avx2 = BinaryBuilder.analyze_instruction_set(oh; verbose=true)
            @test isa_avx2 == :haswell
        end

        # Delete the build path
        rm(build_path, recursive = true)
    end
end

@testset "Auditor - .dll moving" begin
    begin
        build_path = tempname()
        mkpath(build_path)
        dll_platform = Windows(:x86_64)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], dll_platform)
        cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # First, build libfoo, but with a dumb script that doesn't know to put .dll files in bin
            dumb_script = """
            /usr/bin/make clean
            /usr/bin/make install libdir=\$prefix/lib
            """

            @test build(ur, "foo", libfoo_products(prefix), libfoo_script, dll_platform, prefix; autofix=false)
        end

        # Test that libfoo puts its .dll's into lib, even on windows:
        @test !isfile(joinpath(prefix, "bin", "libfoo.dll"))
        @test isfile(joinpath(prefix, "lib", "libfoo.dll"))

        # Test that `audit()` moves it to `bin`.
        BinaryBuilder.audit(prefix; platform=dll_platform, verbose=true, autofix=true)
        @test isfile(joinpath(prefix, "bin", "libfoo.dll"))
        @test !isfile(joinpath(prefix, "lib", "libfoo.dll"))
    end
end

@testset "Auditor - absolute paths" begin
    prefix = Prefix(tempname())
    try
        sharedir = joinpath(prefix.path, "share")
        mkpath(sharedir)
        open(joinpath(sharedir, "foo.conf"), "w") do f
            write(f, "share_dir = \"$sharedir\"")
        end

        # Test that `audit()` warns about an absolute path within the prefix
        @info("Expecting a warning about share/foo.conf:")
        BinaryBuilder.audit(prefix)
    finally
        rm(prefix.path; recursive=true)
    end
end
@testset "GitHub releases build.jl reconstruction" begin
    # Download some random release that is relatively small
    product_hashes = product_hashes_from_github_release("staticfloat/OggBuilder", "v1.3.3-6")

    # Ground truth hashes for each product
    true_product_hashes = Dict(
        "arm-linux-gnueabihf"        => (
            "Ogg.v1.3.3.arm-linux-gnueabihf.tar.gz",
            "a70830decaee040793b5c6a8f8900ed81720aee51125a3aab22440b26e45997a"
        ),
        "x86_64-unknown-freebsd11.1" => (
            "Ogg.v1.3.3.x86_64-unknown-freebsd11.1.tar.gz",
            "a87e432f1e80880200b18decc33df87634129a2f9d06200cae89ad8ddde477b6"
        ),
        "i686-w64-mingw32"           => (
            "Ogg.v1.3.3.i686-w64-mingw32.tar.gz",
            "3f6f6f524137a178e9df7cb5ea5427de6694c2a44ef78f1491d22bd9c6c8a0e8"
        ),
        "powerpc64le-linux-gnu"      => (
            "Ogg.v1.3.3.powerpc64le-linux-gnu.tar.gz",
            "b133194a9527f087bbf942f77bf6a953cb8c277c98f609479bce976a31a5ba39"
        ),
        "x86_64-linux-gnu"           => (
            "Ogg.v1.3.3.x86_64-linux-gnu.tar.gz",
            "6ef771242553b96262d57b978358887a056034a3c630835c76062dca8b139ea6"
        ),
        "x86_64-apple-darwin14"      => (
            "Ogg.v1.3.3.x86_64-apple-darwin14.tar.gz",
            "077898aed79bbce121c5e3d5cd2741f50be1a7b5998943328eab5406249ac295"
        ),
        "x86_64-linux-musl"          => (
            "Ogg.v1.3.3.x86_64-linux-musl.tar.gz",
            "a7ff6bf9b28e1109fe26c4afb9c533f7df5cf04ace118aaae76c2fbb4c296b99"
        ),
        "aarch64-linux-gnu"          => (
            "Ogg.v1.3.3.aarch64-linux-gnu.tar.gz",
            "ce2329057df10e4f1755da696a5d5e597e1a9157a85992f143d03857f4af259c"
        ),
        "i686-linux-musl"            => (
            "Ogg.v1.3.3.i686-linux-musl.tar.gz",
            "d8fc3c201ea40feeb05bc84d7159286584427f54776e316ef537ff32347c4007"
        ),
        "x86_64-w64-mingw32"         => (
            "Ogg.v1.3.3.x86_64-w64-mingw32.tar.gz",
            "c6afdfb19d9b0d20b24a6802e49a1fbb08ddd6a2d1da7f14b68f8627fd55833a"
        ),
        "i686-linux-gnu"             => (
            "Ogg.v1.3.3.i686-linux-gnu.tar.gz",
            "1045d82da61ff9574d91f490a7be0b9e6ce17f6777b6e9e94c3c897cc53dd284"
        ),
    )

    @test length(product_hashes) == length(true_product_hashes)

    for target in keys(true_product_hashes)
        @test haskey(product_hashes, target)
        product_platform = extract_platform_key(product_hashes[target][1])
        true_product_platform = extract_platform_key(true_product_hashes[target][1])
        @test product_platform == true_product_platform
        @test product_hashes[target][2] == true_product_hashes[target][2]
    end
end

include("wizard.jl")

# Run the package tests if we ask for it
if lowercase(get(ENV, "BINARYBUILDER_PACKAGE_TESTS", "false") ) == "true"
    cd("package_tests") do
        include(joinpath(pwd(), "runtests.jl"))
    end
end
