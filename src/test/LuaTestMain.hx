package test;

class LuaTestMain {
    static function main() {
        new TestScript().run(()->{trace("heyo");});
    }
}