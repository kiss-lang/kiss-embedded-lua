package test;

import kiss_embedded_lua.AsyncEmbeddedScript;
import kiss.Prelude;

@:build(kiss_embedded_lua.AsyncEmbeddedScript.build("kiss-embedded-lua", "src/test/TestDSL.kiss", "TestScript.dsl"))
class TestScript extends AsyncEmbeddedScript {}
