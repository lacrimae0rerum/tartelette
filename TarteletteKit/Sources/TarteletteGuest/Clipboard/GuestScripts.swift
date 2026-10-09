import Foundation
import TarteletteCore

/// Guest-side commands as argv arrays, ready for any `GuestTransport`.
///
/// Every command runs through `userCommand(_:os:)`, which sets a UTF-8 locale (the guest agent's
/// environment only has PATH and TERM) and, on macOS, re-executes as the console user when the
/// agent happens to run as root, so pasteboard access lands in the logged-in Aqua session.
public enum GuestScripts {
  /// Where clipboard payloads are staged inside the guest. Expanded by the guest shell.
  public static func defaultStagingRoot(for os: VMOperatingSystem) -> String {
    os == .macOS ? "~/Library/Caches/Tartelette/Clipboard" : "~/.cache/tartelette/clipboard"
  }

  // MARK: Wrapping

  static let macOSUserGuard = #"""
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    if [ "$(id -u)" = 0 ]; then
      u=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null)
      if [ -n "$u" ] && [ "$u" != root ]; then
        exec /bin/launchctl asuser "$(/usr/bin/id -u "$u")" /usr/bin/sudo -H -u "$u" /usr/bin/env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "$@"
      fi
    fi
    exec "$@"
    """#

  static let linuxUserGuard = #"""
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    exec "$@"
    """#

  /// Wraps a guest argv with the locale and console-user guard.
  public static func userCommand(_ argv: [String], os: VMOperatingSystem) -> [String] {
    ["/bin/sh", "-c", os == .macOS ? macOSUserGuard : linuxUserGuard, "tartelette"] + argv
  }

  /// A POSIX shell snippet with the transfer helpers (`x` expands `~`, `h` hashes stdin).
  static let prelude = #"""
    x() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;; *) printf '%s' "$1" ;; esac; }
    h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

    """#

  static func shell(_ body: String, _ arguments: [String], os: VMOperatingSystem) -> [String] {
    userCommand(["/bin/sh", "-c", prelude + body, "tartelette"] + arguments, os: os)
  }

  // MARK: Verified transfer primitives (POSIX sh, macOS and Linux)

  /// Prints `<size> <sha256>` of a guest file.
  public static func fileInfo(_ path: String, os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      f=$(x "$1"); [ -f "$f" ] || { echo "No such file: $f" >&2; exit 4; }
      printf '%s %s\n' "$(wc -c < "$f" | tr -d ' ')" "$(h < "$f")"
      """#, [path], os: os)
  }

  /// Streams a whole guest file to stdout.
  public static func readFile(_ path: String, os: VMOperatingSystem) -> [String] {
    shell(#"exec cat "$(x "$1")""#, [path], os: os)
  }

  /// Prints one SHA-256 per `chunkSize` block of a guest file.
  public static func chunkHashes(_ path: String, chunkSize: Int, os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      f=$(x "$1"); n=$2; s=$(wc -c < "$f" | tr -d ' '); i=0
      while [ $((i * n)) -lt "$s" ]; do dd if="$f" bs="$n" skip=$i count=1 2>/dev/null | h; i=$((i + 1)); done
      """#, [path, String(chunkSize)], os: os)
  }

  /// Streams block `index` (of `chunkSize` bytes) of a guest file to stdout.
  public static func readChunk(_ path: String, index: Int, chunkSize: Int, os: VMOperatingSystem) -> [String] {
    shell(#"exec dd if="$(x "$1")" bs="$2" skip="$3" count=1 2>/dev/null"#, [path, String(chunkSize), String(index)], os: os)
  }

  /// Writes stdin to a guest file (creating parent directories) and prints its SHA-256.
  public static func writeFile(_ path: String, os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      f=$(x "$1"); umask 077; mkdir -p "$(dirname "$f")" && cat > "$f" && h < "$f"
      """#, [path], os: os)
  }

  /// Creates (or empties) a guest file.
  public static func truncateFile(_ path: String, os: VMOperatingSystem) -> [String] {
    shell(#"f=$(x "$1"); umask 077; mkdir -p "$(dirname "$f")" && : > "$f""#, [path], os: os)
  }

  /// Writes stdin at block `index` of a guest file and prints the SHA-256 of that block.
  public static func writeChunk(_ path: String, index: Int, chunkSize: Int, os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      f=$(x "$1"); dd of="$f" bs="$2" seek="$3" conv=notrunc 2>/dev/null
      dd if="$f" bs="$2" skip="$3" count=1 2>/dev/null | h
      """#, [path, String(chunkSize), String(index)], os: os)
  }

  /// Removes guest files or directories.
  public static func remove(_ paths: [String], os: VMOperatingSystem) -> [String] {
    shell(#"for p in "$@"; do rm -rf "$(x "$p")"; done"#, paths, os: os)
  }

  /// Splits a guest path into its folder (`~` kept for the guest shell to expand) and last component.
  static func splitGuestPath(_ path: String) -> (directory: String, name: String) {
    var trimmed = path
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let slash = trimmed.lastIndex(of: "/") else { return (".", trimmed) }
    let directory = String(trimmed[..<slash])
    return (directory.isEmpty ? "/" : directory, String(trimmed[trimmed.index(after: slash)...]))
  }

  /// Archives guest paths (`tar -czf`) into `archive`. Each path is stored under its last component
  /// (as `./name`, so names starting with "-" aren't read as options); `~` is expanded in the guest.
  /// Callers must reject duplicate last components first (`GuestTransferError.checkUniqueNames`).
  public static func createArchive(_ archive: String, paths: [String], os: VMOperatingSystem) -> [String] {
    var arguments = [archive]
    for path in paths {
      let (directory, name) = splitGuestPath(path)
      arguments += [directory, name]
    }
    // Rebuilds "$@" as `-C <dir> ./<name>` triples: each step consumes one (dir, name) pair from
    // the front and appends the expanded triple at the end.
    return shell(
      #"""
      out=$(x "$1"); shift; umask 077; mkdir -p "$(dirname "$out")" || exit 1
      n=$#; i=0
      while [ "$i" -lt "$n" ]; do d=$(x "$1"); f=$2; shift 2; set -- "$@" -C "$d" "./$f"; i=$((i + 2)); done
      COPYFILE_DISABLE=1 exec tar -czf "$out" "$@"
      """#, arguments, os: os)
  }

  /// Prints the total size in bytes of guest files or folders (`du`, so rounded up to blocks).
  public static func pathSizes(_ paths: [String], os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      t=0
      for p in "$@"; do k=$(du -sk "$(x "$p")" 2>/dev/null | cut -f1); t=$((t + ${k:-0})); done
      printf '%s\n' "$((t * 1024))"
      """#, paths, os: os)
  }

  /// Keeps the `keep` most recently modified staging folders in `root` and removes older ones, and
  /// likewise keeps only the `keep` newest transfer archives (`<UUID>.tgz`) left behind by
  /// interrupted transfers.
  ///
  /// Scoped tightly: only direct children of `root` named like a UUID (the folders and archives
  /// the bridge creates) are candidates, and nothing happens unless `root` is a Tartelette staging
  /// folder.
  public static func pruneStaging(_ root: String, keep: Int, os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      r=$(x "$1"); keep=$2
      case "$r" in *[Tt]artelette*) ;; *) exit 0 ;; esac
      [ -d "$r" ] || exit 0
      i=0; j=0
      ls -1t "$r" 2>/dev/null | while IFS= read -r e; do
        case "$e" in
          ????????-????-????-????-????????????)
            [ -d "$r/$e" ] || continue
            i=$((i + 1))
            [ "$i" -gt "$keep" ] && rm -rf "$r/$e"
            ;;
          ????????-????-????-????-????????????.tgz)
            [ -f "$r/$e" ] || continue
            j=$((j + 1))
            [ "$j" -gt "$keep" ] && rm -f "$r/$e"
            ;;
        esac
      done
      exit 0
      """#, [root, String(max(0, keep))], os: os)
  }

  /// Extracts a guest archive into `directory` without overwriting: clashing names get a " 2", " 3"…
  /// suffix. Deletes the archive and prints the final path of every top-level entry.
  public static func extractArchive(_ archive: String, into directory: String, os: VMOperatingSystem) -> [String] {
    shell(
      #"""
      a=$(x "$1"); d=$(x "$2"); t="$d/.tartelette-$$"
      mkdir -p "$t" && tar -xzf "$a" -C "$t" || { rm -rf "$t"; rm -f "$a"; exit 1; }
      rm -f "$a"
      for e in "$t"/* "$t"/.[!.]*; do
        [ -e "$e" ] || continue
        n=$(basename "$e"); dst="$d/$n"; k=2
        while [ -e "$dst" ]; do
          case "$n" in ?*.*) dst="$d/${n%.*} $k.${n##*.}" ;; *) dst="$d/$n $k" ;; esac
          k=$((k + 1))
        done
        mv "$e" "$dst" && printf '%s\n' "$dst"
      done
      rmdir "$t" 2>/dev/null
      exit 0
      """#, [archive, directory], os: os)
  }

  // MARK: macOS pasteboard (JXA)

  static func jxa(_ script: String, _ arguments: [String]) -> [String] {
    userCommand(["/usr/bin/osascript", "-l", "JavaScript", "-e", script] + arguments, os: .macOS)
  }

  static let jxaCommon = #"""
    ObjC.import('AppKit');
    function board(name) { return name ? $.NSPasteboard.pasteboardWithName(name) : $.NSPasteboard.generalPasteboard; }
    function emit(obj) {
      $.NSFileHandle.fileHandleWithStandardOutput.writeData($(JSON.stringify(obj)).dataUsingEncoding($.NSUTF8StringEncoding));
    }
    function expand(p) { return $(p).stringByExpandingTildeInPath.js; }
    function utf8(data) { return $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js; }
    """#

  /// Prints `{"changeCount": N}` for the guest pasteboard.
  public static func macOSChangeCount(pasteboardName: String? = nil) -> [String] {
    jxa(
      jxaCommon + #"""
        function run(argv) { emit({ changeCount: Number(board(argv[0]).changeCount) }); }
        """#, [pasteboardName ?? ""])
  }

  /// Prints a JSON manifest of the guest pasteboard: inline base64 flavours when their encoded size
  /// stays under `inlineLimit`, otherwise flavours staged to a JSON file in `stagingDirectory`;
  /// file URLs are listed with sizes for a separate verified transfer.
  public static func macOSRead(pasteboardName: String? = nil, stagingDirectory: String, inlineLimit: Int) -> [String] {
    jxa(
      jxaCommon + #"""
        var TYPES = ['public.utf8-plain-text', 'public.rtf', 'public.html', 'public.png', 'public.tiff'];
        function sizeOf(fm, path, isDirectory) {
          if (!isDirectory) { return Number(fm.attributesOfItemAtPathError(path, null).fileSize); }
          var total = 0, e = fm.enumeratorAtPath(path), f;
          while (!(f = e.nextObject).isNil()) { var a = e.fileAttributes; if (!a.isNil()) total += Number(a.fileSize); }
          return total;
        }
        function run(argv) {
          var pb = board(argv[0]), stage = expand(argv[1]), limit = parseInt(argv[2], 10);
          var fm = $.NSFileManager.defaultManager;
          var result = { changeCount: Number(pb.changeCount), items: [], files: [], staged: null };
          var urls = pb.readObjectsForClassesOptions($([$.NSURL]), $({ 'NSPasteboardURLReadingFileURLsOnlyKey': true }));
          if (!urls.isNil()) {
            for (var i = 0; i < urls.count; i++) {
              var path = urls.objectAtIndex(i).path.js, isDir = Ref();
              if (!fm.fileExistsAtPathIsDirectory(path, isDir)) continue;
              result.files.push({ path: path, size: sizeOf(fm, path, isDir[0]), directory: !!isDir[0] });
            }
          }
          if (result.files.length > 0) { emit(result); return; }
          var items = pb.pasteboardItems;
          if (items.isNil() || items.count === 0) { emit(result); return; }
          var first = items.objectAtIndex(0), declared = ObjC.deepUnwrap(first.types) || [];
          var encoded = [], total = 0;
          TYPES.forEach(function (type) {
            if (declared.indexOf(type) < 0) return;
            var data = first.dataForType(type);
            if (data.isNil() || data.length === 0) return;
            var b64 = data.base64EncodedStringWithOptions(0).js;
            total += b64.length;
            encoded.push({ type: type, data: b64 });
          });
          if (total <= limit) {
            result.items = encoded;
          } else {
            fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(stage, true, $(), null);
            var file = stage + '/' + $.NSUUID.UUID.UUIDString.js + '.json';
            var body = $(JSON.stringify({ items: encoded }));
            body.writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null);
            result.staged = { path: file, size: Number(fm.attributesOfItemAtPathError(file, null).fileSize) };
          }
          emit(result);
        }
        """#, [pasteboardName ?? "", stagingDirectory, String(inlineLimit)])
  }

  /// Replaces the guest pasteboard with a JSON payload `{"items":[{type,data}],"files":[path]}` read
  /// from stdin, or from `payloadFile` (which is then deleted). Prints `{"changeCount": N,
  /// "itemCount": M}`, where M is the number of items the pasteboard server holds afterwards.
  public static func macOSWrite(pasteboardName: String? = nil, payloadFile: String? = nil) -> [String] {
    jxa(
      jxaCommon + #"""
        function run(argv) {
          var pb = board(argv[0]), file = argv[1] ? expand(argv[1]) : '';
          var data = file ? $.NSData.dataWithContentsOfFile(file) : $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
          if (file) { $.NSFileManager.defaultManager.removeItemAtPathError(file, null); }
          var payload = JSON.parse(utf8(data));
          var writers = [];
          if (payload.items && payload.items.length > 0) {
            var item = $.NSPasteboardItem.alloc.init;
            payload.items.forEach(function (rep) {
              item.setDataForType($.NSData.alloc.initWithBase64EncodedStringOptions(rep.data, 0), rep.type);
            });
            writers.push(item);
          }
          (payload.files || []).forEach(function (p) {
            // One eager item per file (NSURL writers promise later items lazily).
            var fileItem = $.NSPasteboardItem.alloc.init;
            fileItem.setStringForType($.NSURL.fileURLWithPath(expand(p)).absoluteString, 'public.file-url');
            writers.push(fileItem);
          });
          pb.clearContents;
          if (writers.length > 0) pb.writeObjects($(writers));
          // writeObjects hands items to the pasteboard server asynchronously; osascript exits right
          // after this, which would drop every item but the first. Reading each item back makes the
          // server take them all before we report.
          var written = pb.pasteboardItems, count = written.isNil() ? 0 : Number(written.count);
          for (var i = 0; i < count; i++) {
            var item = written.objectAtIndex(i), types = item.types;
            for (var k = 0; k < types.count; k++) item.dataForType(types.objectAtIndex(k));
          }
          emit({ changeCount: Number(pb.changeCount), itemCount: count });
        }
        """#, [pasteboardName ?? "", payloadFile ?? ""])
  }

  // MARK: Linux clipboard (wl-clipboard, xclip or xsel)

  /// Exit status used by the Linux scripts when no clipboard tool or desktop session is available.
  public static let linuxUnsupportedStatus: Int32 = 3

  static let linuxSetup = #"""
    [ -n "$XDG_RUNTIME_DIR" ] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    if [ -z "$WAYLAND_DISPLAY" ] && [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then export WAYLAND_DISPLAY=wayland-0; fi
    [ -n "$DISPLAY" ] || export DISPLAY=:0
    if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-paste >/dev/null 2>&1; then T=wl
    elif command -v xclip >/dev/null 2>&1; then T=xclip
    elif command -v xsel >/dev/null 2>&1; then T=xsel
    else
      echo "No clipboard tool in the guest. Install wl-clipboard or xclip and log in to a desktop session (Cirrus Labs Linux images are server-only)." >&2
      exit 3
    fi
    types() { case $T in wl) wl-paste --list-types 2>/dev/null ;; xclip) xclip -selection clipboard -t TARGETS -o 2>/dev/null ;; xsel) echo text/plain ;; esac; }
    get() { case $T in
      wl) wl-paste --no-newline --type "$1" 2>/dev/null ;;
      xclip) if [ "$1" = text/plain ]; then xclip -selection clipboard -o 2>/dev/null; else xclip -selection clipboard -t "$1" -o 2>/dev/null; fi ;;
      xsel) xsel --clipboard --output 2>/dev/null ;;
    esac; }
    put() { case $T in
      wl) wl-copy --type "$1" >/dev/null 2>&1 ;;
      xclip) if [ "$1" = text/plain ]; then xclip -selection clipboard -i >/dev/null 2>&1; else xclip -selection clipboard -t "$1" -i >/dev/null 2>&1; fi ;;
      xsel) xsel --clipboard --input >/dev/null 2>&1 ;;
    esac; }
    has() { types | grep -Eq "$1"; }
    token() { { types; get text/plain | head -c 65536; if has '^image/png$'; then get image/png | head -c 1048576; fi; } | h | cut -c1-15; }

    """#

  /// Prints `{"changeCount": N}` where N is a content hash token (Linux has no change counter).
  public static func linuxChangeCount() -> [String] {
    shell(linuxSetup + #"printf '{"changeCount":%s}' "$((0x$(token)))""#, [], os: .linux)
  }

  /// Prints a JSON manifest; flavours are staged to files in `stagingDirectory` and listed with UTIs.
  public static func linuxRead(stagingDirectory: String) -> [String] {
    shell(
      linuxSetup + #"""
        d=$(x "$1"); mkdir -p "$d"; tok=$((0x$(token)))
        printf '{"changeCount":%s,"items":[' "$tok"; sep=""
        if has '^text/uri-list$'; then :; else
          for pair in 'text/plain|public.utf8-plain-text|^(text/plain|text/plain;charset=utf-8|UTF8_STRING|STRING)$' \
                      'text/html|public.html|^text/html$' 'image/png|public.png|^image/png$'; do
            mime=${pair%%|*}; rest=${pair#*|}; uti=${rest%%|*}; pattern=${rest#*|}
            if [ "$T" = xsel ] && [ "$mime" != text/plain ]; then continue; fi
            has "$pattern" || continue
            f=$(mktemp "$d/item.XXXXXX"); get "$mime" > "$f"; s=$(wc -c < "$f" | tr -d ' ')
            if [ "$s" -gt 0 ]; then printf '%s{"type":"%s","path":"%s","size":%s}' "$sep" "$uti" "$f" "$s"; sep=,; else rm -f "$f"; fi
          done
        fi
        printf '],"files":['; sep=""
        if has '^text/uri-list$'; then
          get text/uri-list | tr -d '\r' | grep '^file://' | while IFS= read -r uri; do printf '%s{"uri":"%s"}' "$sep" "$uri"; sep=,; done
        fi
        printf ']}'
        """#, [stagingDirectory], os: .linux)
  }

  /// Puts a staged guest file on the clipboard as `mime`, deletes it and prints the new token.
  public static func linuxWrite(mime: String, stagedFile: String) -> [String] {
    shell(
      linuxSetup + #"""
        f=$(x "$2"); put "$1" < "$f"; rm -f "$f"; sleep 0.2
        printf '{"changeCount":%s}' "$((0x$(token)))"
        """#, [mime, stagedFile], os: .linux)
  }
}
