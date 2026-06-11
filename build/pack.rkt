#lang racket/base
;; The package-payload packer: a pure-Racket equivalent of Emscripten's
;; file_packager.py for share.data + share.data.js, so re-packing the package
;; tree needs NO emsdk -- just racket. (It replaced the emsdk-backed packer once
;; verified to build a byte-identical virtual FS and boot the real runtime.)
;;
;; The artifact is trivial: share.data is the package files concatenated
;; back-to-back, and share.data.js is a loader that fetches it and replays each
;; slice into the runtime's virtual FS via the *documented* Emscripten preload
;; ABI the runtime already exports: FS_createPath / FS_createDataFile /
;; addRunDependency / removeRunDependency. The loader does all FS work inside a
;; `preRun` callback, never at import time -- shell-worker.js importScripts() this
;; BEFORE scheme-web.js, so the runtime (and those hooks) don't exist yet at
;; import. See build-wasm.md "Packages as a separate data file".
(require racket/file
         racket/path
         racket/list
         racket/string
         file/sha1
         json
         "config.rkt"
         "util.rkt")

(provide write-data-package! share-preload-entries share-preload-files
         pack-share-data pack-packages extend-data-package! data-package-file-bytes)

;; --- the file list -------------------------------------------------------

;; The preload set, as (mountpoint . source-path) pairs, mirroring stages.rkt's
;; `pack-share-data`: the whole installed share/pkgs tree, the links file, and
;; any in-tree /pkgs/<name> the links file points at (the `(up up #"pkgs" ...)`
;; form -- in-tree source-bootstrap packages; copied-catalog packages use the
;; `(#"pkgs" #"name")` form under /share/pkgs and are covered by the wholesale
;; preload instead. Mirrors `links-pkgs-roots` in racket/src/cs/c/build.zuo
;; (keep the two in sync). A source path that is a directory is walked; a file
;; maps to the mountpoint directly.
(define (links-pkgs-roots links-file)
  (filter values
    (for/list ([e (in-list (call-with-input-file links-file read))])
      (define path (and (pair? e) (pair? (cdr e)) (cadr e)))
      (and (list? path) (= (length path) 4)
           (eq? (car path) 'up) (eq? (cadr path) 'up)
           (equal? (caddr path) #"pkgs")
           (bytes->string/utf-8 (cadddr path))))))

(define (share-preload-entries #:clone [clone clone-dir])
  (define share-pkgs (build-path clone "racket" "share" "pkgs"))
  (define links (build-path clone "racket" "share" "links.rktd"))
  (unless (directory-exists? share-pkgs)
    (error 'pack-share-data-pure "no installed package tree at ~a" share-pkgs))
  (append
   (list (cons "/share/pkgs" share-pkgs))
   (if (file-exists? links) (list (cons "/share/links.rktd" links)) '())
   (if (file-exists? links)
       (for/list ([name (in-list (links-pkgs-roots links))]
                  #:when (directory-exists? (build-path clone "pkgs" name)))
         (cons (string-append "/pkgs/" name) (build-path clone "pkgs" name)))
       '())))

;; Expand the preload entries into a flat list of (virtual-path . real-path),
;; one per file -- exactly the set file_packager would pack. A directory entry
;; is walked recursively (its files mapped under the mountpoint); a file entry
;; maps to the mountpoint itself.
(define (share-preload-files #:clone [clone clone-dir])
  (append-map
   (lambda (e)
     (define mount (car e))
     (define src (cdr e))
     (cond
       [(file-exists? src) (list (cons mount src))]
       [(directory-exists? src)
        (define base (simplify-path (path->complete-path src)))
        (for/list ([p (in-directory src)] #:when (file-exists? p))
          (define rel (find-relative-path base (simplify-path (path->complete-path p))))
          (cons (string-append mount "/"
                               (string-join (map path->string (explode-path rel)) "/"))
                p))]
       [else '()]))
   (share-preload-entries #:clone clone)))

;; --- the data file + loader ----------------------------------------------

;; Every ancestor directory of `vpaths` (absolute virtual paths), parents before
;; children, for the FS_createPath preamble. "/" is implicit (never emitted).
(define (ancestor-dirs vpaths)
  (define seen (make-hash))
  (for ([vp (in-list vpaths)])
    (define comps (cdr (explode-path (string->path vp)))) ; drop leading "/"
    (let loop ([acc '()] [cs (drop-right comps 1)])        ; drop the file name
      (unless (null? cs)
        (define here (append acc (list (path->string (car cs)))))
        (hash-set! seen here #t)
        (loop here (cdr cs)))))
  (sort (hash-keys seen)
        (lambda (a b) (or (< (length a) (length b))
                          (and (= (length a) (length b)) (string<? (string-join a "/") (string-join b "/")))))))

;; The content-addressed cache key for a packed `.data` blob -- the loader's
;; IndexedDB preload cache (file_packager's --use-preload-cache) keys the stored
;; payload on this so it survives across rebuilds when the bytes don't change and
;; is invalidated the moment they do. file_packager uses sha256; Racket ships no
;; built-in sha256, and the value is an opaque equality token (never interpreted
;; client-side), so sha1 is exactly as good -- prefixed so the scheme is explicit.
(define (data-package-uuid data-path)
  (string-append "sha1-" (call-with-input-file data-path sha1)))

;; A single FS_createPath line: parent dir + new component.
(define (fs-create-path-line comps)
  (define parent (if (= (length comps) 1) "/" (string-append "/" (string-join (drop-right comps 1) "/"))))
  (format "Module['FS_createPath'](~a, ~a, true, true);"
          (jsexpr->string parent) (jsexpr->string (last comps))))

;; Write <name>.data + <name>.data.js into `dest` for the given
;; (virtual-path . real-path) file list. The data file is the concatenation of
;; the real files; the loader carries each file's [start,end) and FS_createPath
;; the directory tree. `name` is e.g. "share.data".
(define (write-data-package! #:files files #:dest dest #:name [name "share.data"])
  (make-directory* dest)
  (define data-path (build-path dest name))
  ;; 1. The data blob: concatenate, recording offsets. One pass, streamed.
  (define metas
    (call-with-output-file data-path #:exists 'replace
      (lambda (out)
        (let loop ([fs files] [pos 0] [acc '()])
          (cond
            [(null? fs) (reverse acc)]
            [else
             (define vp (caar fs))
             (define rp (cdar fs))
             (define bs (file->bytes rp))
             (write-bytes bs out)
             (define end (+ pos (bytes-length bs)))
             (loop (cdr fs) end
                   (cons (hasheq 'filename vp 'start pos 'end end) acc))])))))
  (define size (file-size data-path))
  ;; 2. The loader.
  (define vpaths (map (lambda (m) (hash-ref m 'filename)) metas))
  (define create-paths
    (string-join (map fs-create-path-line (ancestor-dirs vpaths)) "\n"))
  (define metadata
    (jsexpr->string (hasheq 'files metas 'remote_package_size size
                            'package_uuid (data-package-uuid data-path))))
  (define js (loader-js name create-paths metadata))
  (call-with-output-file (build-path dest (string-append name ".js")) #:exists 'replace
    (lambda (out) (write-string js out)))
  (info-msg "packed ~a (~a files, ~a bytes) -> ~a" name (length files) size dest)
  (values data-path size))

;; --- extending an existing data package ----------------------------------

;; Recover the loader's manifest (the `{files,remote_package_size}` JSON the
;; loader passes to `loadPackage(...)`) from an already-generated `<name>.js`.
;; The JSON is emitted on a single line by `write-data-package!`, terminated by
;; `);` then the loader's `})();` tail -- anchor on that to bound the match.
(define (read-data-package-manifest js-path)
  (define txt (file->string js-path))
  (define m (regexp-match #px"loadPackage\\((\\{.*\\})\\);\\s*\\}\\)\\(\\);" txt))
  (unless m
    (error 'extend-data-package "cannot find loadPackage(...) manifest in ~a" js-path))
  (string->jsexpr (cadr m)))

;; The bytes of one virtual-path file already packed in `existing-data`, located
;; via the `existing-js` manifest -- or #f if that vpath isn't present. Lets the
;; consume path read the runtime's current `/share/links.rktd` out of `share.data`
;; so it can merge the new package's collection link.
(define (data-package-file-bytes #:data existing-data #:js existing-js vpath)
  (define files (hash-ref (read-data-package-manifest existing-js) 'files))
  (define entry (for/or ([m (in-list files)])
                  (and (equal? (hash-ref m 'filename) vpath) m)))
  (and entry
       (call-with-input-file existing-data
         (lambda (in)
           (file-position in (hash-ref entry 'start))
           (read-bytes (- (hash-ref entry 'end) (hash-ref entry 'start)) in)))))

;; Extend an existing `<name>`/`<name>.js` data package (e.g. a runtime's
;; shipped `share.data`) with additional (virtual-path . real-path) files,
;; writing a fresh pair into `dest`. Used by the cross-SDK consume path
;; (build/consume.rkt) to fold a newly cross-compiled package into the runtime's
;; package payload WITHOUT re-packing the whole tree (the consumer need not ship
;; the full cross-root). New bytes are appended after the existing blob; an
;; `add` vpath that already exists in the manifest is re-pointed to the new
;; slice (the stale bytes become harmless dead space). `name` is e.g.
;; "share.data". Returns (values new-data-path new-size).
(define (extend-data-package! #:data existing-data #:js existing-js
                              #:add add-files #:dest dest #:name [name "share.data"])
  (define manifest (read-data-package-manifest existing-js))
  (define old-files (hash-ref manifest 'files))
  (define add-vpaths (for/hash ([e (in-list add-files)]) (values (car e) #t)))
  ;; Drop any prior entry the add-set replaces (dedup on re-install).
  (define kept (filter (lambda (m) (not (hash-ref add-vpaths (hash-ref m 'filename) #f)))
                       old-files))
  (make-directory* dest)
  (define data-path (build-path dest name))
  ;; New blob = existing bytes (verbatim, offsets preserved) ++ the added files.
  (define base-bytes (file->bytes existing-data))
  (define new-metas
    (call-with-output-file data-path #:exists 'replace
      (lambda (out)
        (write-bytes base-bytes out)
        (let loop ([fs add-files] [pos (bytes-length base-bytes)] [acc '()])
          (cond
            [(null? fs) (reverse acc)]
            [else
             (define bs (file->bytes (cdar fs)))
             (write-bytes bs out)
             (define end (+ pos (bytes-length bs)))
             (loop (cdr fs) end
                   (cons (hasheq 'filename (caar fs) 'start pos 'end end) acc))])))))
  (define size (file-size data-path))
  (define metas (append kept new-metas))
  (define vpaths (map (lambda (m) (hash-ref m 'filename)) metas))
  (define create-paths
    (string-join (map fs-create-path-line (ancestor-dirs vpaths)) "\n"))
  (define metadata
    (jsexpr->string (hasheq 'files metas 'remote_package_size size
                            'package_uuid (data-package-uuid data-path))))
  (call-with-output-file (build-path dest (string-append name ".js")) #:exists 'replace
    (lambda (out) (write-string (loader-js name create-paths metadata) out)))
  (info-msg "extended ~a (+~a files, ~a total, ~a bytes) -> ~a"
            name (length add-files) (length metas) size dest)
  (values data-path size))

;; The loader source. Mirrors file_packager's contract: increments
;; expectedDataFileDownloads, fetches the .data (node readFileSync / browser
;; fetch, honouring locateFile + getPreloadedPackage), FS_createPaths the dirs,
;; gates run() with addRunDependency per file until the slices are written via
;; FS_createDataFile, and runs in preRun so the FS exists. No emsdk internals --
;; only the public Module hooks the runtime already provides.
;;
;; The IndexedDB block reproduces emscripten's --use-preload-cache: after the
;; first download the `.data` blob is cached in IndexedDB keyed on PACKAGE_UUID
;; (a content hash, see `data-package-uuid`), and subsequent loads serve it from
;; the cache, skipping the network. Ported from tools/file_packager.py's
;; `if options.use_preload_cache:` branch (the openDatabase / checkCachedPackage
;; / fetchCachedPackage / cacheRemotePackage helpers + the try/catch preload
;; flow), trimmed to this loader's FS-replay shape and to the browser (the node
;; and getPreloadedPackage paths bypass the cache). DB schema, store names, the
;; 64MB chunking, and the EM_PRELOAD_CACHE database name match upstream so an
;; emscripten-packed payload and this one share a cache layout.
(define (loader-js name create-paths metadata)
  (string-append "
var Module = typeof Module != 'undefined' ? Module : {};
if (!Module['expectedDataFileDownloads']) Module['expectedDataFileDownloads'] = 0;
Module['expectedDataFileDownloads']++;
(() => {
  var isPthread = typeof ENVIRONMENT_IS_PTHREAD != 'undefined' && ENVIRONMENT_IS_PTHREAD;
  var isWasmWorker = typeof ENVIRONMENT_IS_WASM_WORKER != 'undefined' && ENVIRONMENT_IS_WASM_WORKER;
  if (isPthread || isWasmWorker) return;
  var isNode = typeof globalThis.process == 'object' && globalThis.process.versions && globalThis.process.versions.node && globalThis.process.type != 'renderer';
  function loadPackage(metadata) {
    var PACKAGE_NAME = " (jsexpr->string name) ";
    var REMOTE_PACKAGE_NAME = Module['locateFile'] ? Module['locateFile'](PACKAGE_NAME, '') : PACKAGE_NAME;
    var REMOTE_PACKAGE_SIZE = metadata['remote_package_size'];
    async function fetchRemotePackage(packageName) {
      if (isNode) { return new Uint8Array(require('fs').readFileSync(packageName)).buffer; }
      var response = await fetch(packageName);
      if (!response.ok) throw new Error(response.status + ': ' + response.url);
      return await response.arrayBuffer();
    }

    // --- IndexedDB preload cache (emscripten file_packager --use-preload-cache) -
    var PACKAGE_UUID = metadata['package_uuid'];
    // Cache key: the path the package lives at, so two pages on the same origin
    // serving different payloads don't collide. Mirrors file_packager's PACKAGE_PATH.
    var PACKAGE_PATH = '';
    if (typeof window === 'object') {
      PACKAGE_PATH = window['encodeURIComponent'](window.location.pathname.substring(0, window.location.pathname.lastIndexOf('/')) + '/');
    } else if (typeof location !== 'undefined') {
      PACKAGE_PATH = encodeURIComponent(location.pathname.substring(0, location.pathname.lastIndexOf('/')) + '/');
    }
    var IDB_RO = 'readonly', IDB_RW = 'readwrite';
    var DB_NAME = 'EM_PRELOAD_CACHE', DB_VERSION = 1;
    var METADATA_STORE_NAME = 'METADATA', PACKAGE_STORE_NAME = 'PACKAGES';
    // Chromium caps per-entry IndexedDB size, so payloads are stored in 64MB chunks.
    var CHUNK_SIZE = 64 * 1024 * 1024;
    function openDatabase() {
      return new Promise((resolve, reject) => {
        if (typeof indexedDB == 'undefined') { reject(new Error('no IndexedDB')); return; }
        var openRequest = indexedDB.open(DB_NAME, DB_VERSION);
        openRequest.onupgradeneeded = (event) => {
          var db = event.target.result;
          if (db.objectStoreNames.contains(PACKAGE_STORE_NAME)) db.deleteObjectStore(PACKAGE_STORE_NAME);
          db.createObjectStore(PACKAGE_STORE_NAME);
          if (db.objectStoreNames.contains(METADATA_STORE_NAME)) db.deleteObjectStore(METADATA_STORE_NAME);
          db.createObjectStore(METADATA_STORE_NAME);
        };
        openRequest.onsuccess = (event) => resolve(event.target.result);
        openRequest.onerror = reject;
      });
    }
    function checkCachedPackage(db, packageName) {
      return new Promise((resolve, reject) => {
        var transaction = db.transaction([METADATA_STORE_NAME], IDB_RO);
        var getRequest = transaction.objectStore(METADATA_STORE_NAME).get('metadata/' + packageName);
        getRequest.onsuccess = (event) => {
          var result = event.target.result;
          resolve(result && PACKAGE_UUID === result['uuid'] ? result : null);
        };
        getRequest.onerror = reject;
      });
    }
    function fetchCachedPackage(db, packageName, meta) {
      return new Promise((resolve, reject) => {
        var transaction = db.transaction([PACKAGE_STORE_NAME], IDB_RO);
        var packages = transaction.objectStore(PACKAGE_STORE_NAME);
        var chunkCount = meta['chunkCount'], chunksDone = 0, totalSize = 0, chunks = new Array(chunkCount);
        for (var chunkId = 0; chunkId < chunkCount; chunkId++) {
          (function (chunkId) {
            var getRequest = packages.get('package/' + packageName + '/' + chunkId);
            getRequest.onsuccess = (event) => {
              if (!event.target.result) { reject('CachedPackageNotFound for: ' + packageName); return; }
              if (chunkCount == 1) { resolve(event.target.result); return; }
              chunks[chunkId] = event.target.result;
              totalSize += event.target.result.byteLength;
              if (++chunksDone == chunkCount) {
                var tempTyped = new Uint8Array(totalSize), byteOffset = 0;
                for (var i = 0; i < chunkCount; i++) { tempTyped.set(new Uint8Array(chunks[i]), byteOffset); byteOffset += chunks[i].byteLength; }
                resolve(tempTyped.buffer);
              }
            };
            getRequest.onerror = reject;
          })(chunkId);
        }
      });
    }
    function cacheRemotePackage(db, packageName, packageData, packageMeta) {
      return new Promise((resolve, reject) => {
        var packages = db.transaction([PACKAGE_STORE_NAME], IDB_RW).objectStore(PACKAGE_STORE_NAME);
        var chunkCount = Math.ceil(packageData.byteLength / CHUNK_SIZE), finishedChunks = 0, sliceStart = 0;
        for (var chunkId = 0; chunkId < chunkCount; chunkId++) {
          var nextSliceStart = sliceStart + CHUNK_SIZE;
          var putRequest = packages.put(packageData.slice(sliceStart, nextSliceStart), 'package/' + packageName + '/' + chunkId);
          sliceStart = nextSliceStart;
          putRequest.onsuccess = (event) => {
            if (++finishedChunks == chunkCount) {
              var meta = db.transaction([METADATA_STORE_NAME], IDB_RW).objectStore(METADATA_STORE_NAME);
              var putMeta = meta.put({ 'uuid': packageMeta.uuid, 'chunkCount': chunkCount }, 'metadata/' + packageName);
              putMeta.onsuccess = () => resolve(packageData);
              putMeta.onerror = reject;
            }
          };
          putRequest.onerror = reject;
        }
      });
    }

    function runWithFS(Module) {
      // The runtime (scheme-web.js) is instantiated AFTER this loader is
      // imported, so FS_createPath / FS / addRunDependency only exist now, in
      // preRun -- never at import time. (See shell-worker.js import order.)
" create-paths "
      for (var file of metadata['files']) Module['addRunDependency']('fp ' + file['filename']);
      Module['addRunDependency']('datafile_' + PACKAGE_NAME);
      function processPackageData(arrayBuffer) {
        var byteArray = new Uint8Array(arrayBuffer);
        for (var file of metadata['files']) {
          var data = byteArray.subarray(file['start'], file['end']);
          Module['FS_createDataFile'](file['filename'], null, data, true, true, true);
          Module['removeRunDependency']('fp ' + file['filename']);
        }
        Module['removeRunDependency']('datafile_' + PACKAGE_NAME);
      }
      var fetched = Module['getPreloadedPackage'] ? Module['getPreloadedPackage'](REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE) : null;
      if (fetched) { processPackageData(fetched); return; }
      // Node and any browser without IndexedDB: plain fetch, no cache.
      if (isNode || typeof indexedDB == 'undefined' || !PACKAGE_UUID) {
        fetchRemotePackage(REMOTE_PACKAGE_NAME).then(processPackageData);
        return;
      }
      // Browser: serve from the IndexedDB preload cache, populating it on a miss.
      // Any cache error falls back to a direct fetch so loading never depends on IDB.
      var cacheKey = PACKAGE_PATH + PACKAGE_NAME;
      (async () => {
        try {
          var db = await openDatabase();
          var pkgMeta = await checkCachedPackage(db, cacheKey);
          if (pkgMeta) {
            processPackageData(await fetchCachedPackage(db, cacheKey, pkgMeta));
          } else {
            var packageData = await fetchRemotePackage(REMOTE_PACKAGE_NAME);
            try { processPackageData(await cacheRemotePackage(db, cacheKey, packageData, { uuid: PACKAGE_UUID })); }
            catch (e) { console.error(e); processPackageData(packageData); }
          }
        } catch (e) {
          console.error(e);
          console.error('falling back to default preload behavior');
          processPackageData(await fetchRemotePackage(REMOTE_PACKAGE_NAME));
        }
      })();
    }
    if (Module['calledRun']) { runWithFS(Module); }
    else { (Module['preRun'] = Module['preRun'] || []).push(runWithFS); }
  }
  loadPackage(" metadata ");
})();
"))

;; Pack the clone's installed package tree into `dest` (default the wasm out dir,
;; next to scheme-web.*, ready for collect-outputs), with no emsdk. This is the
;; build's `pack-share-data` -- both the full build (after a cache-miss `make`)
;; and the standalone `pack-pkgs` repack call it.
(define (pack-share-data #:dest [dest (clone-wasm-out)] #:clone [clone clone-dir])
  (write-data-package! #:files (share-preload-files #:clone clone) #:dest dest))

;; `pack-packages`: the single, explicit producer of the `share.data` payload --
;; pack the package cross-root (`cross-root`, a clone-shaped tree: cache entry or
;; the live clone) into `dest`. No build step packs `share.data`; the orchestrator
;; (build/stages.rkt `build-runtime`) and the `pack-pkgs` command call this. The
;; binary-only variant (part 2) will hook in here.
(define (pack-packages #:dest dest #:cross-root [cross-root clone-dir])
  (pack-share-data #:dest dest #:clone cross-root))
