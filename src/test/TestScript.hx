package test;

import kiss_embedded_lua.AsyncEmbeddedScript;
import kiss.Prelude;
import test.ExternClass;

@:build(kiss_embedded_lua.AsyncEmbeddedScript.build("kiss-embedded-lua", "src/test/TestDSL.kiss", "TestScript.dsl", ["test.ExternClass"]))
class TestScript extends AsyncEmbeddedScript<TestScript> {}
