using OpenBLAS_jll, OpenBLAS32_jll, MKL_jll, CompilerSupportLibraries_jll
using Pkg, Artifacts, Base.BinaryPlatforms, Libdl, Test

include("utils.jl")

# Compile `dgemm_test.c` and `sgesv_test.c` against the given BLAS/LAPACK
function run_test((test_name, test_expected_outputs), libblas_name, libdirs, interface, backing_libs)
    # We need to configure this C build a bit
    cflags = String[
        "-g",
    ]
    if interface == :ILP64
        push!(cflags, "-DILP64")
    end
    
    ldflags = String[
        # Teach it to find that libblas and its dependencies at build time
        ("-L$(cygpath(libdir))" for libdir in libdirs)...,
        "-l$(libblas_name)",
    ]

    if !Sys.iswindows()
        # Teach it to find that libblas and its dependencies at run time
        append!(ldflags, ("-Wl,-rpath,$(cygpath(libdir))" for libdir in libdirs))
    end

    mktempdir() do dir
        @info("Compiling `$(test_name)` against $(libblas_name) ($(backing_libs)) in $(dir)")
        srcdir = joinpath(@__DIR__, test_name)
        p = run(ignorestatus(`$(make) -sC $(cygpath(srcdir)) prefix=$(cygpath(dir)) CFLAGS="$(join(cflags, " "))" LDFLAGS="$(join(ldflags, " "))"`))
        if !success(p)
            @error("compilation failed", srcdir, prefix=dir, cflags=join(cflags, " "), ldflags=join(ldflags, " "))
        end
        @test success(p)
    
        env = Dict(
            # We need to tell it how to find CSL at run-time
            LIBPATH_env => append_libpath(libdirs),
            "LBT_DEFAULT_LIBS" => backing_libs,
        )
        cmd = `$(dir)/$(test_name)`
        output = capture_output(addenv(cmd, env))

        # Test to make sure the test ran properly
        has_expected_output = all(occursin(expected, output) for expected in test_expected_outputs)
        if !has_expected_output
            # Uh-oh, we didn't get what we expected.  Time to debug!
            @error("Test failed, got output:")
            println(output)

            # If we're not on CI, launch `gdb`
            if isempty(get(ENV, "CI", ""))
                @warn("Launching `gdb`")
                cmd = `gdb $(cmd)`
                env["LBT_VERBOSE"] = "1"
                run(addenv(cmd, env))
            end
        end
        @test has_expected_output
    end
end

# our tests
dgemm = ("dgemm_test", ("||C||^2 is:  24.3384",))
sgesv = ("sgesv_test", ("||b||^2 is:   3.0000",))

# Build version that links against vanilla OpenBLAS
openblas_interface = :LP64
if Sys.WORD_SIZE == 64 && Sys.ARCH != :aarch64
    openblas_interface = :ILP64
end
openblas_jll_libname = splitext(basename(OpenBLAS_jll.libopenblas_path)[4:end])[1]
@testset "Vanilla OpenBLAS_jll ($(openblas_interface))" begin
    run_test(dgemm, openblas_jll_libname, OpenBLAS_jll.LIBPATH_list, openblas_interface, "")
    run_test(sgesv, openblas_jll_libname, OpenBLAS_jll.LIBPATH_list, openblas_interface, "")
end

# Build version that links against vanilla OpenBLAS32
@testset "Vanilla OpenBLAS32_jll (LP64)" begin
    run_test(dgemm, "openblas", OpenBLAS32_jll.LIBPATH_list, :LP64, "")
    run_test(sgesv, "openblas", OpenBLAS32_jll.LIBPATH_list, :LP64, "")
end

# Next, build a version that links against `libblastrampoline`, and tell
# the trampoline to forwards calls to `OpenBLAS_jll`
lbt_dir = joinpath(get_blastrampoline_dir(), binlib)
@testset "LBT -> OpenBLAS_jll ($(openblas_interface))" begin
    libdirs = unique(vcat(OpenBLAS_jll.LIBPATH_list..., CompilerSupportLibraries_jll.LIBPATH_list..., lbt_dir))
    run_test(dgemm, "blastrampoline", libdirs, openblas_interface, OpenBLAS_jll.libopenblas_path)
    run_test(sgesv, "blastrampoline", libdirs, openblas_interface, OpenBLAS_jll.libopenblas_path)
end

# And again, but this time with OpenBLAS32_jll
@testset "LBT -> OpenBLAS32_jll (LP64)" begin
    libdirs = unique(vcat(OpenBLAS32_jll.LIBPATH_list..., CompilerSupportLibraries_jll.LIBPATH_list..., lbt_dir))
    run_test(dgemm, "blastrampoline", libdirs, :LP64, OpenBLAS32_jll.libopenblas_path)
    run_test(sgesv, "blastrampoline", libdirs, :LP64, OpenBLAS32_jll.libopenblas_path)
end

# Test against MKL_jll using `libmkl_rt`, which is :LP64 by default
if MKL_jll.is_available()
    @testset "LBT -> MKL_jll (LP64)" begin
        libdirs = unique(vcat(MKL_jll.LIBPATH_list..., CompilerSupportLibraries_jll.LIBPATH_list..., lbt_dir))
        run_test(dgemm, "blastrampoline", libdirs, :LP64, MKL_jll.libmkl_rt_path)
        run_test(sgesv, "blastrampoline", libdirs, :LP64, MKL_jll.libmkl_rt_path)
    end
end

# Do we have a `blas64.so` somewhere?  If so, test with that for fun
blas64 = dlopen("libblas64", throw_error=false)
if blas64 !== nothing
    @testset "LBT -> libblas64 (ILP64, BLAS)" begin
        run_test(dgemm, "blastrampoline", [lbt_dir], :ILP64, dlpath(blas64))
    end
    # Can't run `sgesv` here as we don't have LAPACK symbols in `libblas64.so`

    # Check if we have a `liblapack` and if we do, run with BOTH
    lapack = dlopen("liblapack64", throw_error=false)
    if lapack !== nothing
        @testset "LBT -> libblas64 + liblapack64 (ILP64, BLAS+LAPACK)" begin
            run_test(dgemm, "blastrampoline", [lbt_dir], :ILP64, "$(dlpath(blas64));$(dlpath(lapack))")
            run_test(sgesv, "blastrampoline", [lbt_dir], :ILP64, "$(dlpath(blas64));$(dlpath(lapack))")
        end
    end
end

# Finally the super-crazy test: build a binary that links against BOTH sets of symbols!
if openblas_interface == :ILP64
    inconsolable = ("inconsolable_test", ("||C||^2 is:  24.3384", "||b||^2 is:   3.0000"))
    @testset "LBT -> OpenBLAS 32 + 64 (LP64 + ILP64)" begin
        libdirs = unique(vcat(OpenBLAS32_jll.LIBPATH_list..., OpenBLAS_jll.LIBPATH_list..., CompilerSupportLibraries_jll.LIBPATH_list..., lbt_dir))
        run_test(inconsolable, "blastrampoline", libdirs, :wild_sobbing, "$(OpenBLAS32_jll.libopenblas_path);$(OpenBLAS_jll.libopenblas_path)")
    end
end
