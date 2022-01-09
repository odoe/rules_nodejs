"Wrapper macro setting convenient defaults for ts_project rule"

load("//ts/private:ts_project.bzl", "lib", _ts_project_rule = "ts_project")
load("//ts/private:ts_config.bzl", "write_tsconfig")
load("//ts/private:ts_valid_tsconfig.bzl", "validate_options")
load("@build_bazel_rules_nodejs//third_party/github.com/bazelbuild/bazel-skylib:lib/partial.bzl", "partial")
load("@build_bazel_rules_nodejs//third_party/github.com/bazelbuild/bazel-skylib:rules/build_test.bzl", "build_test")
load("@build_bazel_rules_nodejs//:index.bzl", "js_library")

def ts_project(
        name = "tsconfig",
        tsconfig = None,
        srcs = None,
        args = [],
        deps = [],
        extends = None,
        allow_js = False,
        declaration = False,
        source_map = False,
        declaration_map = False,
        resolve_json_module = None,
        preserve_jsx = False,
        composite = False,
        incremental = False,
        emit_declaration_only = False,
        transpiler = None,
        ts_build_info_file = None,
        tsc = None,
        validate = True,
        declaration_dir = None,
        out_dir = None,
        root_dir = None,
        link_workspace_root = False,
        **kwargs):
    """Compiles one TypeScript project using `tsc --project`

    This is a drop-in replacement for the `tsc` rule automatically generated for the "typescript"
    package, typically loaded from `@npm//typescript:index.bzl`. Unlike bare `tsc`, this rule understands
    the Bazel interop mechanism (Providers) so that this rule works with others that produce or consume
    TypeScript typings (`.d.ts` files).

    Unlike `ts_library`, this rule is the thinnest possible layer of Bazel interoperability on top
    of the TypeScript compiler. It shifts the burden of configuring TypeScript into the tsconfig.json file.
    See https://github.com/bazelbuild/rules_nodejs/blob/master/docs/TypeScript.md#alternatives
    for more details about the trade-offs between the two rules.

    Some TypeScript options affect which files are emitted, and Bazel wants to know these ahead-of-time.
    So several options from the tsconfig file must be mirrored as attributes to ts_project.
    See https://www.typescriptlang.org/v2/en/tsconfig for a listing of the TypeScript options.

    Any code that works with `tsc` should work with `ts_project` with a few caveats:

    - `ts_project` always produces some output files, or else Bazel would never run it.
      Therefore you shouldn't use it with TypeScript's `noEmit` option.
      See `tsc_test` under the Alternatives section above.
    - Bazel requires that the `outDir` (and `declarationDir`) be set to
      `bazel-out/[target architecture]/bin/path/to/package`
      so we override whatever settings appear in your tsconfig.
    - Bazel expects that each output is produced by a single rule.
      Thus if you have two `ts_project` rules with overlapping sources (the same `.ts` file
      appears in more than one) then you get an error about conflicting `.js` output
      files if you try to build both together.
      Worse, if you build them separately then the output directory will contain whichever
      one you happened to build most recently. This is highly discouraged.

    > Note: in order for TypeScript to resolve relative references to the bazel-out folder,
    > we recommend that the base tsconfig contain a rootDirs section that includes all
    > possible locations they may appear.
    >
    > We hope this will not be needed in some future release of TypeScript.
    > Follow https://github.com/microsoft/TypeScript/issues/37257 for more info.
    >
    > For example, if the base tsconfig file relative to the workspace root is
    > `path/to/tsconfig.json` then you should configure like:
    >
    > ```
    > "compilerOptions": {
    >     "rootDirs": [
    >         ".",
    >         "../../bazel-out/host/bin/path/to",
    >         "../../bazel-out/darwin-fastbuild/bin/path/to",
    >         "../../bazel-out/darwin_arm64-fastbuild/bin/path/to",
    >         "../../bazel-out/k8-fastbuild/bin/path/to",
    >         "../../bazel-out/x64_windows-fastbuild/bin/path/to",
    >         "../../bazel-out/darwin-dbg/bin/path/to",
    >         "../../bazel-out/k8-dbg/bin/path/to",
    >         "../../bazel-out/x64_windows-dbg/bin/path/to",
    >     ]
    > }
    > ```
    >
    > See some related discussion including both "rootDirs" and "paths" for a monorepo setup
    > using custom import paths:
    > https://github.com/bazelbuild/rules_nodejs/issues/2298

    ### Issues when running non-sandboxed

    When using a non-sandboxed spawn strategy (which is the default on Windows), you may
    observe these problems which require workarounds:

    1) Bazel deletes outputs from the previous execution before running `tsc`.
       This causes a problem with TypeScript's incremental mode: if the `.tsbuildinfo` file
       is not known to be an output of the rule, then Bazel will leave it in the output
       directory, and when `tsc` runs, it may see that the outputs written by the prior
       invocation are up-to-date and skip the emit of these files. This will cause Bazel
       to intermittently fail with an error that some outputs were not written.
       This is why we depend on `composite` and/or `incremental` attributes to be provided,
       so we can tell Bazel to expect a `.tsbuildinfo` output to ensure it is deleted before a
       subsequent compilation.
       At present, we don't do anything useful with the `.tsbuildinfo` output, and this rule
       does not actually have incremental behavior. Deleting the file is actually
       counter-productive in terms of TypeScript compile performance.
       Follow https://github.com/bazelbuild/rules_nodejs/issues/1726

    2) When using Project References, TypeScript will expect to verify that the outputs of referenced
       projects are up-to-date with respect to their inputs.
       (This is true even without using the `--build` option).
       When using a non-sandboxed spawn strategy, `tsc` can read the sources from other `ts_project`
       rules in your project, and will expect that the `tsconfig.json` file for those references will
       indicate where the outputs were written. However the `outDir` is determined by this Bazel rule so
       it cannot be known from reading the `tsconfig.json` file.
       This problem is manifested as a TypeScript diagnostic like
       `error TS6305: Output file '/path/to/execroot/a.d.ts' has not been built from source file '/path/to/execroot/a.ts'.`
       As a workaround, you can give the Windows "fastbuild" output directory as the `outDir` in your tsconfig file.
       On other platforms, the value isn't read so it does no harm.
       See https://github.com/bazelbuild/rules_nodejs/tree/stable/packages/typescript/test/ts_project as an example.
       We hope this will be fixed in a future release of TypeScript;
       follow https://github.com/microsoft/TypeScript/issues/37378

    3) When TypeScript encounters an import statement, it adds the source file resolved by that reference
       to the program. However you may have included that source file in a different project, so this causes
       the problem mentioned above where a source file is in multiple programs.
       (Note, if you use Project References this is not the case, TS will know the referenced
       file is part of the other program.)
       This will result in duplicate emit for the same file, which produces an error
       since the files written to the output tree are read-only.
       Workarounds include using using Project References, or simply grouping the whole compilation
       into one program (if this doesn't exceed your time budget).

    Args:
        name: A name for the target.

            We recommend you use the basename (no `.json` extension) of the tsconfig file that should be compiled.

        srcs: List of labels of TypeScript source files to be provided to the compiler.

            If absent, the default is set as follows:
            - Include `**/*.ts[x]` (all TypeScript files in the package).
            - If `allow_js` is set, include `**/*.js[x]` (all JavaScript files in the package).
            - If `resolve_json_module` is set, include `**/*.json` (all JSON files in the package), but exclude `**/package.json`, `**/package-lock.json`, and `**/tsconfig*.json`.

        deps: List of labels of other rules that produce TypeScript typings (.d.ts files)

        tsconfig: Label of the tsconfig.json file to use for the compilation

            To support "chaining" of more than one extended config, this label could be a target that
            provides `TsConfigInfo` such as `ts_config`.

            By default, we assume the tsconfig file is "tsconfig.json" in the same folder as the ts_project rule.

            EXPERIMENTAL: generated tsconfig

            Instead of a label, you can pass a dictionary of tsconfig keys.

            In this case, a tsconfig.json file will be generated for this compilation, in the following way:
            - all top-level keys will be copied by converting the dict to json.
              So `tsconfig = {"compilerOptions": {"declaration": True}}`
              will result in a generated `tsconfig.json` with `{"compilerOptions": {"declaration": true}}`
            - each file in srcs will be converted to a relative path in the `files` section.
            - the `extends` attribute will be converted to a relative path

            Note that you can mix and match attributes and compilerOptions properties, so these are equivalent:

            ```
            ts_project(
                tsconfig = {
                    "compilerOptions": {
                        "declaration": True,
                    },
                },
            )
            ```
            and
            ```
            ts_project(
                declaration = True,
            )
            ```

        extends: Label of the tsconfig file referenced in the `extends` section of tsconfig

            To support "chaining" of more than one extended config, this label could be a target that
            provdes `TsConfigInfo` such as `ts_config`.

        args: List of strings of additional command-line arguments to pass to tsc.

        transpiler: A custom transpiler tool to run that produces the JavaScript outputs instead of `tsc`.

            This attribute accepts a rule or macro with this signature:
            `name, srcs, js_outs, map_outs, **kwargs`
            where the `**kwargs` attribute propagates the tags, visibility, and testonly attributes from `ts_project`.

            If you need to pass additional attributes to the transpiler rule, you can use a
            [partial](https://github.com/bazelbuild/bazel-skylib/blob/main/lib/partial.bzl)
            to bind those arguments at the "make site", then pass that partial to this attribute where it
            will be called with the remaining arguments.
            See the packages/typescript/test/ts_project/swc directory for an example.

            When a custom transpiler is used, then the `ts_project` macro expands to these targets:

            - `[name]` - the default target is a `js_library` which can be included in the `deps` of downstream rules.
                Note that it will successfully build *even if there are typecheck failures* because the `tsc` binary
                is not needed to produce the default outputs.
                This is considered a feature, as it allows you to have a faster development mode where type-checking
                is not on the critical path.
            - `[name]_typecheck` - provides typings (`.d.ts` files) as the default output,
               therefore building this target always causes the typechecker to run.
            - `[name]_typecheck_test` - a
               [`build_test`](https://github.com/bazelbuild/bazel-skylib/blob/main/rules/build_test.bzl)
               target which simply depends on the `[name]_typecheck` target.
               This ensures that typechecking will be run under `bazel test` with
               [`--build_tests_only`](https://docs.bazel.build/versions/main/user-manual.html#flag--build_tests_only).
            - `[name]_typings` - internal target which runs the binary from the `tsc` attribute
            -  Any additional target(s) the custom transpiler rule/macro produces.
                Some rules produce one target per TypeScript input file.

            By default, `ts_project` expects `.js` outputs to be written in the same action
            that does the type-checking to produce `.d.ts` outputs.
            This is the simplest configuration, however `tsc` is slower than alternatives.
            It also means developers must wait for the type-checking in the developer loop.

            In theory, Persistent Workers (via the `supports_workers` attribute) remedies the
            slow compilation time, however it adds additional complexity because the worker process
            can only see one set of dependencies, and so it cannot be shared between different
            `ts_project` rules. That attribute is documented as experimental, and may never graduate
            to a better support contract.

        tsc: Label of the TypeScript compiler binary to run.

            For example, `tsc = "@my_deps//typescript/bin:tsc"`
            Or you can pass a custom compiler binary instead.

            One possible compiler is the Angular compiler, provided by the
            `@angular/compiler-cli` package as the `ngc` binary, which can be set typically with
            `tsc = "@npm//@angular/compiler-cli/bin:ngc"`
            Note that you'll also need to pass `.html` and `.css` files to the `srcs` of the `ts_project`
            so that they're declared as inputs for the Angular compiler to read them.

            An example can be found in the rules_nodejs repo under `packages/typescript/test/ts_project/ngc`.

            > To use the `ngc` program from Angular versions prior to 11, you'll need a fix for
            > https://github.com/angular/angular/issues/36290
            > To apply the fix, you can use the patch-package package to apply this patch:
            > https://gist.github.com/alexeagle/ba44b2601bd7c953d29c6e8ec44d1ef9

        validate: boolean; whether to check that the tsconfig JSON settings match the attributes on this target.

            Set this to `False` to skip running our validator, in case you have a legitimate reason for these to differ,
            e.g. you have a setting enabled just for the editor but you want different behavior when Bazel runs `tsc`.

        root_dir: a string specifying a subdirectory under the input package which should be consider the
            root directory of all the input files.
            Equivalent to the TypeScript --rootDir option.
            By default it is '.', meaning the source directory where the BUILD file lives.

        out_dir: a string specifying a subdirectory under the bazel-out folder where outputs are written.
            Equivalent to the TypeScript --outDir option.
            Note that Bazel always requires outputs be written under a subdirectory matching the input package,
            so if your rule appears in path/to/my/package/BUILD.bazel and out_dir = "foo" then the .js files
            will appear in bazel-out/[arch]/bin/path/to/my/package/foo/*.js.
            By default the out_dir is '.', meaning the packages folder in bazel-out.

        allow_js: boolean; Specifies whether TypeScript will read .js and .jsx files. When used with declaration,
            TypeScript will generate .d.ts files from .js files.

        resolve_json_module: None | boolean; Specifies whether TypeScript will read .json files. Defaults to None.
            If set to True or False and tsconfig is a dict, resolveJsonModule is set in the generated config file.
            If set to None and tsconfig is a dict, resolveJsonModule is unset in the generated config and typescript
            default or extended tsconfig value will be load bearing.

        declaration_dir: a string specifying a subdirectory under the bazel-out folder where generated declaration
            outputs are written. Equivalent to the TypeScript --declarationDir option.
            By default declarations are written to the out_dir.

        declaration: if the `declaration` bit is set in the tsconfig.
            Instructs Bazel to expect a `.d.ts` output for each `.ts` source.
        source_map: if the `sourceMap` bit is set in the tsconfig.
            Instructs Bazel to expect a `.js.map` output for each `.ts` source.
        declaration_map: if the `declarationMap` bit is set in the tsconfig.
            Instructs Bazel to expect a `.d.ts.map` output for each `.ts` source.
        preserve_jsx: if the `jsx` value is set to "preserve" in the tsconfig.
            Instructs Bazel to expect a `.jsx` or `.jsx.map` output for each `.tsx` source.
        composite: if the `composite` bit is set in the tsconfig.
            Instructs Bazel to expect a `.tsbuildinfo` output and a `.d.ts` output for each `.ts` source.
        incremental: if the `incremental` bit is set in the tsconfig.
            Instructs Bazel to expect a `.tsbuildinfo` output.
        emit_declaration_only: if the `emitDeclarationOnly` bit is set in the tsconfig.
            Instructs Bazel *not* to expect `.js` or `.js.map` outputs for `.ts` sources.
        ts_build_info_file: the user-specified value of `tsBuildInfoFile` from the tsconfig.
            Helps Bazel to predict the path where the .tsbuildinfo output is written.

        link_workspace_root: Link the workspace root to the bin_dir to support absolute requires like 'my_wksp/path/to/file'.
            If source files need to be required then they can be copied to the bin_dir with copy_to_bin.

        **kwargs: passed through to underlying rule, allows eg. visibility, tags
    """

    if srcs == None:
        include = ["**/*.ts", "**/*.tsx"]
        exclude = []
        if allow_js == True:
            include.extend(["**/*.js", "**/*.jsx"])
        if resolve_json_module == True:
            include.append("**/*.json")
            exclude.extend(["**/package.json", "**/package-lock.json", "**/tsconfig*.json"])
        srcs = native.glob(include, exclude)
    tsc_deps = deps

    if type(extends) == type([]):
        fail("As of rules_nodejs 3.0, extends should have a single value, not a list.\n" +
             "Use a ts_config rule to group together a chain of extended tsconfigs.")

    if type(tsconfig) == type(dict()):
        # Copy attributes <-> tsconfig properties
        # TODO: fail if compilerOptions includes a conflict with an attribute?
        compiler_options = tsconfig.setdefault("compilerOptions", {})
        source_map = compiler_options.setdefault("sourceMap", source_map)
        declaration = compiler_options.setdefault("declaration", declaration)
        declaration_map = compiler_options.setdefault("declarationMap", declaration_map)
        emit_declaration_only = compiler_options.setdefault("emitDeclarationOnly", emit_declaration_only)
        allow_js = compiler_options.setdefault("allowJs", allow_js)
        if resolve_json_module != None:
            resolve_json_module = compiler_options.setdefault("resolveJsonModule", resolve_json_module)

        # These options are always passed on the tsc command line so don't include them
        # in the tsconfig. At best they're redundant, but at worst we'll have a conflict
        if "outDir" in compiler_options.keys():
            out_dir = compiler_options.pop("outDir")
        if "declarationDir" in compiler_options.keys():
            declaration_dir = compiler_options.pop("declarationDir")
        if "rootDir" in compiler_options.keys():
            root_dir = compiler_options.pop("rootDir")

        # FIXME: need to remove keys that have a None value?
        write_tsconfig(
            name = "_gen_tsconfig_%s" % name,
            config = tsconfig,
            files = [s for s in srcs if lib.is_ts_src(s, allow_js) or lib.is_json_src(s, resolve_json_module)],
            extends = Label("%s//%s:%s" % (native.repository_name(), native.package_name(), name)).relative(extends) if extends else None,
            out = "tsconfig_%s.json" % name,
        )

        # From here, tsconfig becomes a file, the same as if the
        # user supplied a tsconfig.json InputArtifact
        tsconfig = "tsconfig_%s.json" % name

    else:
        if tsconfig == None:
            tsconfig = "tsconfig.json"

        if validate:
            validate_options(
                name = "_validate_%s_options" % name,
                target = "//%s:%s" % (native.package_name(), name),
                declaration = declaration,
                source_map = source_map,
                declaration_map = declaration_map,
                preserve_jsx = preserve_jsx,
                composite = composite,
                incremental = incremental,
                ts_build_info_file = ts_build_info_file,
                emit_declaration_only = emit_declaration_only,
                resolve_json_module = resolve_json_module,
                allow_js = allow_js,
                tsconfig = tsconfig,
                extends = extends,
            )
            tsc_deps = tsc_deps + ["_validate_%s_options" % name]

    typings_out_dir = declaration_dir if declaration_dir else out_dir
    tsbuildinfo_path = ts_build_info_file if ts_build_info_file else name + ".tsbuildinfo"
    js_outs = []
    map_outs = []
    typings_outs = []
    typing_maps_outs = []

    if not emit_declaration_only:
        exts = {
            "*": ".js",
            ".jsx": ".jsx",
            ".tsx": ".jsx",
        } if preserve_jsx else {"*": ".js"}
        js_outs.extend(lib.out_paths(srcs, out_dir, root_dir, allow_js, exts))
    if source_map and not emit_declaration_only:
        exts = {
            "*": ".js.map",
            ".tsx": ".jsx.map",
        } if preserve_jsx else {"*": ".js.map"}
        map_outs.extend(lib.out_paths(srcs, out_dir, root_dir, False, exts))
    if declaration or composite:
        typings_outs.extend(lib.out_paths(srcs, typings_out_dir, root_dir, allow_js, {"*": ".d.ts"}))
    if declaration_map:
        typing_maps_outs.extend(lib.out_paths(srcs, typings_out_dir, root_dir, allow_js, {"*": ".d.ts.map"}))

    tsc_js_outs = []
    tsc_map_outs = []
    if not transpiler:
        tsc_js_outs = js_outs
        tsc_map_outs = map_outs
        tsc_target_name = name
    else:
        # To stitch together a tree of ts_project where transpiler is a separate rule,
        # we have to produce a few targets
        tsc_target_name = "%s_typings" % name
        transpile_target_name = "%s_transpile" % name
        typecheck_target_name = "%s_typecheck" % name
        test_target_name = "%s_typecheck_test" % name

        common_kwargs = {
            "tags": kwargs.get("tags", []),
            "visibility": kwargs.get("visibility", None),
            "testonly": kwargs.get("testonly", None),
        }
        if type(transpiler) == "function" or type(transpiler) == "rule":
            transpiler(
                name = transpile_target_name,
                srcs = srcs,
                js_outs = js_outs,
                map_outs = map_outs,
                **common_kwargs
            )
        elif partial.is_instance(transpiler):
            partial.call(
                transpiler,
                name = transpile_target_name,
                srcs = srcs,
                js_outs = js_outs,
                map_outs = map_outs,
                **common_kwargs
            )
        else:
            fail("transpiler attribute should be a rule/macro, a skylib partial, or the string 'tsc'. Got " + type(transpiler))

        # Users should build this target to get a failed build when typechecking fails
        native.filegroup(
            name = typecheck_target_name,
            srcs = [tsc_target_name],
            # This causes the DeclarationInfo to be produced, which in turn triggers the tsc action to typecheck
            output_group = "types",
            **common_kwargs
        )

        # Ensures the target above gets built under `bazel test --build_tests_only`
        build_test(
            name = test_target_name,
            targets = [typecheck_target_name],
            **common_kwargs
        )

        # Default target produced by the macro gives the js and map outs, with the transitive dependencies.
        js_library(
            name = name,
            srcs = js_outs + map_outs,
            # Include the tsc target so that this js_library can be a valid dep for downstream ts_project
            # or other DeclarationInfo-aware rules.
            deps = deps + [tsc_target_name],
            **common_kwargs
        )

    if not len(tsc_js_outs) and not len(typings_outs):
        fail("""ts_project target "//{}:{}" is configured to produce no outputs.

Note that ts_project must know the srcs in advance in order to predeclare the outputs.
Check the srcs attribute to see that some .ts files are present (or .js files with allow_js=True).
""".format(native.package_name(), name))

    _ts_project_rule(
        name = tsc_target_name,
        srcs = srcs,
        args = args,
        deps = tsc_deps,
        tsconfig = tsconfig,
        extends = extends,
        declaration_dir = declaration_dir,
        out_dir = out_dir,
        root_dir = root_dir,
        js_outs = tsc_js_outs,
        map_outs = tsc_map_outs,
        typings_outs = typings_outs,
        typing_maps_outs = typing_maps_outs,
        buildinfo_out = tsbuildinfo_path if composite or incremental else None,
        tsc = tsc,
        link_workspace_root = link_workspace_root,
        transpile = not transpiler,
        **kwargs
    )