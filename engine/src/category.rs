/// Coarse grouping used for treemap colour and the "Kinds" breakdown. Groups file types into
/// a fixed set of kinds.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Category {
    Folder = 0,
    Image,
    Video,
    Audio,
    Document,
    Archive,
    Code,
    Application,
    Data,
    Font,
    Other,
}

pub const CATEGORY_COUNT: usize = 11;

impl Category {
    pub fn from_u8(v: u8) -> Category {
        match v {
            0 => Category::Folder,
            1 => Category::Image,
            2 => Category::Video,
            3 => Category::Audio,
            4 => Category::Document,
            5 => Category::Archive,
            6 => Category::Code,
            7 => Category::Application,
            8 => Category::Data,
            9 => Category::Font,
            _ => Category::Other,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Category::Folder => "Folders",
            Category::Image => "Images",
            Category::Video => "Video",
            Category::Audio => "Audio",
            Category::Document => "Documents",
            Category::Archive => "Archives",
            Category::Code => "Code",
            Category::Application => "Applications",
            Category::Data => "Data",
            Category::Font => "Fonts",
            Category::Other => "Other",
        }
    }

    /// Classify by file name (case-insensitive extension, plus exact-name rules). No filesystem access.
    pub fn classify(name: &str) -> Category {
        // Apple dyld shared caches are large extensionless databases: without this rule the
        // biggest files on a developer Mac all land in Other. Exact prefixes, case-sensitive:
        // the real files are Apple's lowercase names; anything in that namespace is their cache.
        if name.starts_with("dyld_shared_cache") || name.starts_with("dyld_sim_shared_cache") {
            return Category::Data;
        }
        let ext = match name.rfind('.') {
            Some(i) if i > 0 && i + 1 < name.len() => &name[i + 1..],
            _ => return Category::Other,
        };
        let mut buf = [0u8; 12];
        if ext.len() > buf.len() {
            return Category::Other;
        }
        for (i, b) in ext.bytes().enumerate() {
            buf[i] = b.to_ascii_lowercase();
        }
        let ext = std::str::from_utf8(&buf[..ext.len()]).unwrap_or("");
        match ext {
            "png" | "jpg" | "jpeg" | "gif" | "heic" | "heif" | "tif" | "tiff" | "bmp" | "webp"
            | "raw" | "cr2" | "nef" | "arw" | "dng" | "svg" | "psd" | "ico" | "icns" => {
                Category::Image
            }
            "mov" | "mp4" | "m4v" | "avi" | "mkv" | "webm" | "mpg" | "mpeg" | "wmv" | "flv"
            | "prores" => Category::Video,
            "mp3" | "m4a" | "aac" | "wav" | "aif" | "aiff" | "flac" | "ogg" | "opus" | "caf"
            | "mid" | "midi" => Category::Audio,
            "dmg" | "iso" | "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "7z" | "rar" | "zst"
            | "pkg" | "xar" | "cab" => Category::Archive,
            "ttf" | "otf" | "woff" | "woff2" | "ttc" | "dfont" => Category::Font,
            "swift" | "rs" | "c" | "h" | "m" | "mm" | "cpp" | "hpp" | "cc" | "py" | "js" | "ts"
            | "tsx" | "jsx" | "java" | "kt" | "go" | "rb" | "php" | "sh" | "zsh" | "bash" | "pl"
            | "lua" | "cs" | "html" | "css" | "scss" | "sql" | "yml" | "yaml" | "toml" | "o"
            | "a" | "class" | "pyc" => Category::Code,
            "app" | "exe" | "dylib" | "so" | "framework" | "bundle" | "kext" | "appex" => {
                Category::Application
            }
            "db" | "sqlite" | "sqlite3" | "json" | "plist" | "xml" | "csv" | "parquet" | "bin"
            | "dat" | "mdb" | "realm" | "log" => Category::Data,
            "txt" | "md" | "rtf" | "pdf" | "doc" | "docx" | "pages" | "key" | "ppt" | "pptx"
            | "numbers" | "xls" | "xlsx" | "odt" | "epub" | "tex" => Category::Document,
            _ => Category::Other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dyld_caches_are_data_including_suffixed_variants() {
        assert_eq!(Category::classify("dyld_shared_cache_arm64e"), Category::Data);
        assert_eq!(Category::classify("dyld_shared_cache_x86_64"), Category::Data);
        assert_eq!(Category::classify("dyld_sim_shared_cache_arm64"), Category::Data);
        assert_eq!(Category::classify("dyld_sim_shared_cache_arm64.01"), Category::Data);
    }

    #[test]
    fn dyld_prefix_does_not_catch_lookalike_names() {
        assert_eq!(Category::classify("dyld_notes.txt"), Category::Document);
        assert_eq!(Category::classify("dyld_notes"), Category::Other);
        assert_eq!(Category::classify("my_dyld_shared_cache_arm64"), Category::Other);
        assert_eq!(Category::classify("DYLD_shared_cache_arm64"), Category::Other);
        assert_eq!(Category::classify("dyld"), Category::Other);
    }

    #[test]
    fn extension_table_still_classifies_known_types() {
        assert_eq!(Category::classify("photo.HEIC"), Category::Image);
        assert_eq!(Category::classify("main.swift"), Category::Code);
        assert_eq!(Category::classify("libSystem.dylib"), Category::Application);
        assert_eq!(Category::classify("store.plist"), Category::Data);
        assert_eq!(Category::classify("archive.tar.gz"), Category::Archive);
        assert_eq!(Category::classify("no_extension"), Category::Other);
    }
}
