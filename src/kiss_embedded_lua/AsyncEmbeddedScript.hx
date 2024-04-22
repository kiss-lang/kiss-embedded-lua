package kiss_embedded_lua;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Compiler;
using haxe.macro.ExprTools;

import kiss.Kiss;
import kiss.Reader;
using kiss.Helpers;

#elseif !lua
import vm.lua.Lua;
#end

#if !lua
import kiss.Prelude;
import kiss.Stream;
import haxe.io.Path;
using haxe.io.Path;
using StringTools;
#end

typedef Continuation = Void->Void;

class AsyncEmbeddedScript {
    #if lua
    public static var instructions = [];
    public static var printCurrentInstruction = true;
    public static var autoCC = true;
    #end
    #if (!macro && !lua)
    private var interp = new Lua();
    private var scriptFile = "";

    public function run(cc:Continuation) {
        var code = sys.io.File.getContent(scriptFile);

        interp.run(code);

        interp.setGlobalVar("cc", cc);
        interp.run("__kiss_embedded_lua_AsyncEmbeddedScript.instructions[0](nil, false, cc)");

        // trace(globals);
        // globals.instructions[0](cc);
    }
    #end

    #if macro
    public static function build(dslHaxelib:String, dslFile:String, scriptFile:String, luaOutputDir="lua"):Array<Field> {
        var config = Compiler.getConfiguration();
        if (["cpp", "js"].contains(Std.string(config.platform))) {
            var args = config.args.copy();

            var luaScriptFile = luaOutputDir + "/" + scriptFile.withoutExtension().withExtension("lua");
            var luaArgs = ["-lua", luaScriptFile, "--dce", "full", "-D", "lua-vanilla"];

            var libsToRemove = ["hxnodejs", "hxcpp", "linc_lua", "hxvm-lua"];

            while (args.length > 0) {
                switch (args.shift()) {
                    case "-js" | "-cpp":
                        args.shift();
                    case "-cp":
                        var cp = args.shift();

                        var add = true;
                        for (lib in libsToRemove) {
                            if (cp.contains('/${lib}/')) add = false;
                        }
                        if (add) {
                            luaArgs.push("-cp");
                            luaArgs.push(cp);
                        }
                    case "-D":
                        var d = args.shift();

                        var add = true;
                        for (lib in libsToRemove) {
                            if (d.contains(lib)) add = false;
                        }
                        if (add) {
                            luaArgs.push("-D");
                            luaArgs.push(d);
                        }
                    case "--main":
                        var otherMain = args.shift();
                        var parts = otherMain.split(".");
                        parts.pop();
                        parts.push(scriptFile.withoutExtension());

                        luaArgs.push("--main");
                        luaArgs.push(parts.join("."));
                    case "--macro":
                        switch (args.shift()) {
                            case "tink.SyntaxHub.use()":
                            case mac:
                                luaArgs.push("--macro");
                                luaArgs.push(mac);
                        }
                    case "--cmd":
                        args.shift();
                    case arg:
                        luaArgs.push(arg);
                }
            }

            Prelude.assertProcess("haxe", luaArgs);

            return [{
                name: "new",
                access: [APublic],
                pos: Context.currentPos(),
                kind: FFun({
                    args: [],
                    expr: macro {
                        scriptFile = $v{luaScriptFile};
                    }
                })
            }];
        } else if (Std.string(config.platform) == "lua") {
            var k = Kiss.defaultKissState();
            k.file = scriptFile;
            var classPath = Context.getPosInfos(Context.currentPos()).file;
            var loadingDirectory = Path.directory(classPath);
            var classFields = []; // Kiss.build() will already include Context.getBuildFields()

            if (dslHaxelib.length > 0) {
                dslFile = Path.join([Helpers.libPath(dslHaxelib), dslFile]);
            }

            // This brings in the DSL's functions and global variables.
            // As a side-effect, it also fills the KissState with the macros and reader macros that make the DSL syntax
            classFields = classFields.concat(Kiss.build(dslFile, k));

            scriptFile = Path.join([loadingDirectory, scriptFile]);

            Context.registerModuleDependency(Context.getLocalModule(), scriptFile);
            k.fieldList = [];

            var commandList:Array<Expr> = [];
            Kiss._try(() -> {
                #if profileKiss
                Kiss.measure('Compiling kiss: $scriptFile', () -> {
                #end
                    function process(nextExp) {
                        nextExp = Kiss._try(()->Kiss.macroExpand(nextExp, k));
                        if (nextExp == null) return;
                        var stateChanged = k.stateChanged;

                        // Allow packing multiple commands into one exp with a (commands <...>) statement
                        switch (nextExp.def) {
                            case CallExp({pos: _, def: Symbol("commands")},
                            commands):
                                for (exp in commands) {
                                    process(exp);
                                }
                                return;
                            default:
                        }

                        var exprString = Reader.toString(nextExp.def);
                        var fieldCount = k.fieldList.length;
                        var expr = Kiss._try(()->Kiss.readerExpToHaxeExpr(nextExp, k));
                        if (expr == null || Kiss.isEmpty(expr))
                            return;

                        // Detect whether the scripter forgot to reference cc. If they did, insert a cc call.
                        var referencesCC = false;

                        function checkSubExps(exp: Expr) {
                            switch (exp.expr) {
                                case EConst(CIdent("cc")):
                                    referencesCC = true;
                                default:
                                    exp.iter(checkSubExps);
                            }
                        }
                        expr.iter(checkSubExps);

                        if (!referencesCC) {
                            expr = macro {
                                $expr;
                                if (AsyncEmbeddedScript.autoCC) {
                                    cc();
                                }
                            };
                        }

                        expr = macro { if (AsyncEmbeddedScript.printCurrentInstruction) Prelude.print($v{exprString}); $expr; };
                        expr = expr.expr.withMacroPosOf(nextExp);
                        if (expr != null) {
                            var c = macro function(self, skipping, cc) {
                                $expr;
                            };
                            commandList.push(c.expr.withMacroPosOf(nextExp));
                        }

                        // This return is essential for type unification of concat() and push() above... ugh.
                        return;
                    }
                    Reader.readAndProcess(Stream.fromFile(scriptFile), k, process);
                    null;
                #if profileKiss
                });
                #end
            });

            classFields = classFields.concat(k.fieldList);

            classFields.push({
                name: "main",
                access: [AStatic],
                pos: Context.currentPos(),
                kind: FFun({
                    args: [],
                    expr: macro {AsyncEmbeddedScript.instructions = $a{commandList};}
                })
            });

            return classFields;
        } else {
            throw 'Unsupported target for kiss-embedded-lua: ${config.platform}';
        }
    }
    #end
}