package kiss_embedded_lua;

#if macro
import sys.FileSystem;
using haxe.io.Path;

import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Compiler;
import haxe.macro.Type;
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

import kiss.Prelude;

typedef Continuation = Void->Void;

#if lua
class Globals {
    public static var self:Dynamic;
    public static var clazz:Dynamic;
    public static var onFinish:Continuation;
}
#end

enum ExternTreeNode {
    Clazz(c:Class<Dynamic>);
    Package(p:Map<String,ExternTreeNode>);
}

class AsyncEmbeddedScript<T:AsyncEmbeddedScript<T>> {
    #if lua
    public static var instructions = [];
    public static var printCurrentInstruction = true;
    public static var autoCC = true;
    private static var instructionPointer = 0;
    @:keep
    private static function cc() {
        if (instructionPointer >= instructions.length) {
            kiss_embedded_lua.AsyncEmbeddedScript.Globals.onFinish();
        } else {
            instructions[instructionPointer++](kiss_embedded_lua.AsyncEmbeddedScript.Globals.self, false, cc);
        }
    }
    public function new() {}
    #end
    #if (!macro && !lua)
    private var interp = new Lua();
    private var scriptFile = "";

    // __init() is overridden by the build macro
    private function __init() {}
    public function new() { __init(); }

    // __setGlobals() is overriden by the build macro
    private function __setGlobals(interp, onFinish) {}
    public function run(onFinish:Continuation) {
        var code = sys.io.File.getContent(scriptFile);

        interp.run(code);

        __setGlobals(interp, onFinish);

        interp.run("__kiss_embedded_lua_AsyncEmbeddedScript.cc()");

        // trace(globals);
        // globals.instructions[0](cc);
    }
    #end

    #if macro
    public static function initWithExterns(externClasses:Array<String>) {
        Context.onAfterTyping((types) -> {
            for (clazz in externClasses) {
                Compiler.exclude(clazz, true);
            }
        });
    }

    public static function build(dslHaxelib:String, dslFile:String, scriptFile:String, luaOutputDir="lua", externClasses:Array<String> = null):Array<Field> {
        var config = Compiler.getConfiguration();
        var clazz = Context.getLocalClass().get();
        var type = clazz.superClass.params[0];
        var type = switch (type) {
            case TInst(classRef, []):
                var ct = classRef.get();
                TPath({pack: ct.pack, name: ct.name});
            default:
                throw "Can't get type name from " + Std.string(type);
        }

        var classFields = [];
        var supported = false;
        // Target language build:
        if (["cpp", "js"].contains(Std.string(config.platform))) {
            supported = true;
            var args = config.args.copy();

            var luaScriptFile = luaOutputDir + "/" + scriptFile.withoutExtension().withExtension("lua");

            var scriptLastUpdated = FileSystem.stat(Context.getPosInfos(Context.currentPos()).file.directory() + "/" + scriptFile).mtime;
            var luaLastUpdated = if (FileSystem.exists(luaScriptFile)) {
                FileSystem.stat(luaScriptFile).mtime;
            } else {
                new Date(0, 0, 0, 0, 0, 0);
            }

            if (luaLastUpdated.getTime() > scriptLastUpdated.getTime()) {
                Prelude.printStr('\nNot recompiling ${luaScriptFile}\n');
            } else {
                var luaArgs = ["-lua", luaScriptFile, "--dce", "full", "-D", "lua-vanilla"];
                var luaManualArgs = ["-lua", luaScriptFile, "--dce", "full", "-D", "lua-vanilla"];

                var libsToRemove = ["hxnodejs", "hxcpp", "linc_lua", "hxvm-lua"];

                while (args.length > 0) {
                    switch (args.shift()) {
                        case "-js" | "-cpp":
                            args.shift();
                        case "-cp":
                            var cp = Path.normalize(args.shift());

                            var add = true;
                            for (lib in libsToRemove) {
                                if (cp.contains('/${lib}/')) add = false;
                            }
                            if (add) {
                                luaArgs.push("-cp");
                                luaArgs.push(cp);
                                luaManualArgs.push("-cp");
                                luaManualArgs.push(cp);
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
                                luaManualArgs.push("-D");
                                luaManualArgs.push(d);
                            }
                        case "--main":
                            var otherMain = args.shift();
                            var parts = otherMain.split(".");
                            parts.pop();
                            parts.push(scriptFile.withoutExtension());

                            luaArgs.push("--main");
                            luaArgs.push(parts.join("."));
                            luaManualArgs.push("--main");
                            luaManualArgs.push(parts.join("."));
                        case "--macro":
                            switch (args.shift()) {
                                case "tink.SyntaxHub.use()":
                                case mac:
                                    luaArgs.push("--macro");
                                    luaArgs.push(mac);
                                    luaManualArgs.push("--macro");
                                    luaManualArgs.push('"${mac.replace('"', '\\\\"')}"');
                            }
                        case "--cmd":
                            args.shift();
                        case arg:
                            luaArgs.push(arg);
                            luaManualArgs.push(arg);
                    }
                }
                
                if (externClasses != null) {
                    luaArgs.push("--macro");
                    luaArgs.push('kiss_embedded_lua.AsyncEmbeddedScript.initWithExterns([${[for (ec in externClasses) '"' + ec + '"'].join(",")}])');
                    luaManualArgs.push("--macro");
                    luaManualArgs.push('"kiss_embedded_lua.AsyncEmbeddedScript.initWithExterns([${[for (ec in externClasses) '\\\\"' + ec + '\\\\"'].join(",")}])"');
                } else {
                    externClasses = [];
                }

                Prelude.printStr("\n");
                Prelude.printStr('haxe ${luaManualArgs.join(" ")}');
                Prelude.printStr("\n");
                Prelude.printStr(Prelude.assertProcess("haxe", luaArgs));
            }

            classFields = [{
                name: "__init",
                access: [APrivate, AOverride],
                pos: Context.currentPos(),
                kind: FFun({
                    args: [],
                    expr: macro {
                        scriptFile = $v{luaScriptFile};
                    }
                })
            }, {
                name: "__setGlobals",
                access: [APublic, AOverride],
                pos: Context.currentPos(),
                kind: FFun({
                    args: [{name: "interp", type: Helpers.parseComplexType("vm.lua.Lua")}, {name: "onFinish"}],
                    expr: macro {
                        var classObject = {};
                        for (field in Type.getClassFields($i{clazz.name})) {
                            Reflect.setField(classObject, field, Reflect.field($i{clazz.name}, field));
                        }
                        var rootMap = new Map();
                        var externTree = kiss_embedded_lua.AsyncEmbeddedScript.ExternTreeNode.Package(rootMap);
                        for (externClass in $v{externClasses}) {
                            var pkgParts = externClass.split(".");
                            var currentPackageMap = rootMap;
                            while (pkgParts.length > 0) {
                                var currentPartStr = pkgParts.shift();
                                // If we are at the end of the type module
                                // put the class in the map
                                if (pkgParts.length == 0) {
                                    currentPackageMap[currentPartStr] = kiss_embedded_lua.AsyncEmbeddedScript.ExternTreeNode.Clazz(Type.resolveClass(externClass));
                                } else {
                                    if (currentPackageMap.exists(currentPartStr)) {
                                        currentPackageMap = switch(currentPackageMap[currentPartStr]) {
                                            case kiss_embedded_lua.AsyncEmbeddedScript.ExternTreeNode.Package(packageMap):
                                                packageMap;
                                            default:
                                                throw 'bad tree';
                                        }
                                    } else {
                                        var newMap = new Map();
                                        currentPackageMap[currentPartStr] = kiss_embedded_lua.AsyncEmbeddedScript.ExternTreeNode.Package(newMap);
                                        currentPackageMap = newMap;
                                    }
                                }

                            }
                        }

                        function toPackageTreeObject (e:kiss_embedded_lua.AsyncEmbeddedScript.ExternTreeNode):Dynamic {
                            return switch (e) {
                                case kiss_embedded_lua.AsyncEmbeddedScript.ExternTreeNode.Clazz(c):
                                    var obj = {};
                                    for (field in Type.getClassFields(c)) {
                                        Reflect.setField(obj, field, Reflect.field(c, field));
                                    }
                                    obj;
                                case kiss_embedded_lua.AsyncEmbeddedScript.ExternTreeNode.Package(packageMap):
                                    var obj = {};
                                    for (key => innerObj in packageMap) {
                                        Reflect.setField(obj, key, toPackageTreeObject(innerObj));
                                    }
                                    obj;
                            };
                        }
                        
                        for (key => treeNode in rootMap) {
                            var obj = toPackageTreeObject(treeNode);
                            interp.setGlobalVar(key, obj);
                        }

                        interp.setGlobalVar("__kiss_embedded_lua_Globals", {
                            self: this,
                            onFinish: onFinish,
                            clazz: classObject
                        });
                    }
                })
            }];
        } 

        // Both builds need this:
        var k = Kiss.defaultKissState();
        k.file = scriptFile;
        var classPath = Context.getPosInfos(Context.currentPos()).file;
        var loadingDirectory = Path.directory(classPath);
        if (dslHaxelib.length > 0) {
            dslFile = Path.join([Helpers.libPath(dslHaxelib), dslFile]);
        }

        // This brings in the DSL's functions and global variables.
        // As a side-effect, it also fills the KissState with the macros and reader macros that make the DSL syntax
        classFields = classFields.concat(Kiss.build(dslFile, k));
 
        // Lua script build:
        if (Std.string(config.platform) == "lua") {
            supported = true;
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
                                if (kiss_embedded_lua.AsyncEmbeddedScript.autoCC) {
                                    cc();
                                }
                            };
                        }

                        expr = macro { if (kiss_embedded_lua.AsyncEmbeddedScript.printCurrentInstruction) kiss.Prelude.print($v{exprString}); $expr; };
                        expr = expr.expr.withMacroPosOf(nextExp);
                        if (expr != null) {
                            var c = macro function(self:$type, skipping, cc) {
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
                    expr: macro {kiss_embedded_lua.AsyncEmbeddedScript.instructions = $a{commandList};}
                })
            });

            // The lua script doesn't actually need a body for any function, it just
            // needs to know the API so it can type-check
            var classFieldStubs = [for (field in classFields) {
                switch (field) {
                    case {
                        name: "new",
                        kind: FFun(fun)
                    }:
                        continue;
                    case {
                        access: access,
                        kind: FFun(fun)
                    } if (!field.access.contains(AStatic) && field.name != "new"):
                        switch (fun.ret) {
                            case TPath({pack: [], name: "Void"}):
                                fun.expr = macro return;
                            default:
                                fun.expr = macro return null;
                        }
                        field;
                    case {
                        name: name,
                        access: access,
                        kind: FFun(fun)
                    } if (field.access.contains(AStatic) && field.name != "main"):
                        var args = [for (arg in fun.args) macro $i{arg.name}];
                        switch (fun.ret) {
                            case TPath({pack: [], name: "Void"}):
                                fun.expr = macro kiss_embedded_lua.AsyncEmbeddedScript.Globals.clazz.$name($a{args});
                            default:
                                fun.expr = macro return kiss_embedded_lua.AsyncEmbeddedScript.Globals.clazz.$name($a{args});
                        }
                        field;
                    default:
                        field;
                }
            }];

            return classFieldStubs;
        }
        if (!supported) {
            throw 'Unsupported target for kiss-embedded-lua: ${config.platform}';
        } else {
            return classFields;
        }
    }
    #end
}