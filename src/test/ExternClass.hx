package test;

import sys.io.File;
import sys.FileSystem;

class ExternClass {
    public static function getFile() {
        return if (FileSystem.exists("src/test/file.txt"))
            File.getContent("src/test/file.txt");
        else
            "";
    }
}
