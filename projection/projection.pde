import java.util.*;

// Limit cache growth to reduce memory usage over long runs
final int MAX_CACHE_IMAGES = 120;      // cap the number of textures kept in memory (lower = safer)
final boolean SHOW_MEM_STATS = true;   // overlay memory / loader info
final int PREFETCH_AHEAD = 24;         // number of upcoming images to prefetch into cache (images are 768x768)

PImage img;
int cols = 7;
int rows = 7;

PVector[][] points;
int draggedI = -1, draggedJ = -1;
float dragThreshold = 10;
boolean editMode = false;
boolean dragAllMode = false;
PVector dragAllOffset = new PVector(0, 0);

// Hot-reload settings
// Watch the top-level `faces` folder under works/stationMaster
String WATCH_DIR = "../faces"; // relative to sketch folder
int POLL_INTERVAL_MS = 1500; // how often to scan folder for changes

ArrayList<String> imageFiles; // absolute paths
int currentImageIndex = 0;
int lastImageChange = 0;
int imageChangeInterval = 7500; // 7.5 seconds

// Track newest file for change detection
String lastNewestName = null;
HashSet<String> lastFileSet = null; // track actual file list to detect changes
boolean newFileTransitioning = false; // flag to prevent normal cycling during new file transition

// LinkedHashMap in access-order mode provides O(1) LRU tracking
LinkedHashMap<String, PImage> textureCache = new LinkedHashMap<String, PImage>(16, 0.75f, true);
ArrayDeque<String> loadQueue = new ArrayDeque<String>(); // O(1) poll() vs ArrayList's O(n) remove(0)
long lastPoll = 0;

// Crossfade / transition state
boolean transitioning = false;
int transitionDuration = 1500; // ms, smooth crossfade (shorter than imageChangeInterval)
long transitionStart = 0;
PImage imgPrev = null;
PImage imgNext = null;
PGraphics pgPrev = null;
PGraphics pgNext = null;
int pgTransitionCount = 0; // track how many transitions we've done
final int PG_RECREATE_INTERVAL = 50; // recreate PGraphics every N transitions to prevent GPU corruption

void setup() {
  fullScreen(P3D);
  pixelDensity(1); // reduce VRAM usage on high-DPI displays
  hint(DISABLE_DEPTH_TEST); // 2D compositing only
  hint(DISABLE_TEXTURE_MIPMAPS); // save memory on textures
  noSmooth(); // reduce GPU cost and memory for filters
  
  // Ensure the watch folder exists
  File wd = new File(sketchPath(WATCH_DIR));
  if (!wd.exists()) wd.mkdirs();

  // Initial scan + queue loads
  pollFolderAndQueueLoads();

  // Start background loader thread
      Thread loader = new Thread(new Runnable() {
    public void run() {
      while (true) {
        String nextFile = null;
        synchronized (loadQueue) {
          if (!loadQueue.isEmpty()) nextFile = loadQueue.poll(); // O(1) operation on ArrayDeque
        }
        if (nextFile != null) {
          try {
            PImage loaded = null;
            try {
              loaded = loadImage(nextFile);
            } catch (OutOfMemoryError oom) {
              println("[loader][OOM] OutOfMemory while loading. Evicting half of cache & requesting GC.");
              emergencyCacheTrim();
              System.gc();
              continue; // skip this cycle
            }
            if (loaded != null) {
              String name = new File(nextFile).getName();
              putTexture(name, loaded);
              println("[loader] loaded -> " + name + " (bytes=" + (loaded.width * loaded.height) + ")");
              
              // Check if this is a newly uploaded file that needs immediate transition
              if (imageFiles != null && imageFiles.size() > 0) {
                String newestName = new File(imageFiles.get(0)).getName();
                if (name.equals(newestName) && currentImageIndex == 0 && img != null && !transitioning) {
                  // This is the newest file and we're waiting for it - start transition now!
                  println("[loader] Triggering transition to newly loaded: " + name);
                  imgPrev = img;
                  imgNext = loaded;
                  transitionStart = millis();
                  transitioning = true;
                  newFileTransitioning = true;
                  // Reset timer so the new image shows for full duration after transition completes
                  lastImageChange = millis();
                }
              }
              
              // If this is the currently selected image, update img reference
              String currentName = getCurrentImageName();
              if (currentName != null && currentName.equals(name)) {
                PImage cur = getTexture(name);
                if (cur != null && cur.width > 0 && cur.height > 0) {
                  img = cur;
                } else {
                  println("[WARN] Retrieved invalid texture for current image: " + name);
                }
              }
            }
          } catch (Exception e) {
            println("Loader thread error: " + e.getMessage());
          }
        } else {
          try { Thread.sleep(150); } catch (InterruptedException e) {}
        }
      }
    }
  });
  loader.setDaemon(true);
  loader.start();

  // Do not exit if no images yet; wait for dynamic additions
  resetPoints();
  loadCoordinates();
  lastImageChange = millis();
}

void loadImageFiles() {
  imageFiles = new ArrayList<String>();
  File dir = new File(sketchPath(WATCH_DIR));
  if (dir.exists() && dir.isDirectory()) {
    File[] files = dir.listFiles();
    if (files == null) return;
    for (File file : files) {
      String name = file.getName();
      String nameLower = name.toLowerCase();
      if (nameLower.startsWith("aligned_") && (nameLower.endsWith(".jpg") || nameLower.endsWith(".png") || nameLower.endsWith(".jpeg"))) {
        imageFiles.add(file.getAbsolutePath());
      }
    }
    // Sort by sequential number (highest -> lowest) so newest uploads appear first
    Collections.sort(imageFiles, new Comparator<String>() {
      public int compare(String a, String b) {
        int numA = extractNumber(new File(a).getName());
        int numB = extractNumber(new File(b).getName());
        // Descending order: highest number first
        return Integer.compare(numB, numA);
      }
    });
  }
  if (imageFiles.size() > 0) {
    println("Found " + imageFiles.size() + " images in " + WATCH_DIR);
    // Debug: print sorted order
    println("Sorted order (highest to lowest):");
    for (int i = 0; i < min(10, imageFiles.size()); i++) {
      String name = new File(imageFiles.get(i)).getName();
      int num = extractNumber(name);
      println("  [" + i + "] " + name + " (num=" + num + ")");
    }
  }
}

// Extract sequential number from aligned_N.ext filename (returns 0 if invalid)
int extractNumber(String filename) {
  try {
    // "aligned_123.jpg" -> "123"
    // Handle case-insensitive matching
    if (!filename.toLowerCase().startsWith("aligned_")) return 0;
    int dotIndex = filename.lastIndexOf('.');
    String numStr = (dotIndex > 0) ? filename.substring(8, dotIndex) : filename.substring(8);
    return Integer.parseInt(numStr);
  } catch (Exception e) {
    return 0;
  }
}

// Return the filename (not path) of the currently selected image, or null
String getCurrentImageName() {
  if (imageFiles == null || imageFiles.size() == 0) return null;
  if (currentImageIndex < 0 || currentImageIndex >= imageFiles.size()) return null;
  return new File(imageFiles.get(currentImageIndex)).getName();
}


void pollFolderAndQueueLoads() {
  // Scan directory for current files
  File dir = new File(sketchPath(WATCH_DIR));
  HashSet<String> currentNames = new HashSet<String>();
  if (dir.exists() && dir.isDirectory()) {
    File[] files = dir.listFiles();
    if (files != null) {
      for (File file : files) {
        String name = file.getName();
        String nameLower = name.toLowerCase();
        if (nameLower.startsWith("aligned_") && (nameLower.endsWith(".jpg") || nameLower.endsWith(".png") || nameLower.endsWith(".jpeg"))) {
          currentNames.add(name);
        }
      }
    }
  }
  
  // Only reload/resort if file set changed
  boolean fileSetChanged = (lastFileSet == null || !lastFileSet.equals(currentNames));
  if (fileSetChanged) {
    println("[poll] File set changed. Reloading and sorting...");
    loadImageFiles();
    lastFileSet = new HashSet<String>(currentNames);
    
    // Reset to newest image when files change
    if (imageFiles != null && imageFiles.size() > 0) {
      String newestName = new File(imageFiles.get(0)).getName();
      boolean newestActuallyChanged = (lastNewestName == null || !newestName.equals(lastNewestName));
      
      // Immediately transition to newest file
      PImage newestTex = getTexture(newestName);
      println("[new-file] newestTex=" + (newestTex != null ? "loaded" : "null") + ", img=" + (img != null ? "exists" : "null") + ", transitioning=" + transitioning);
      
      if (newestTex != null && newestActuallyChanged) {
        // If we have a current image showing, transition smoothly
        if (img != null) {
          // Cancel any ongoing transition first
          if (transitioning) {
            println("[new-file] Canceling ongoing transition");
            transitioning = false;
            if (imgNext != null) img = imgNext; // complete to the target
            imgPrev = null;
            imgNext = null;
            if (pgPrev != null) { pgPrev.dispose(); pgPrev = null; }
            if (pgNext != null) { pgNext.dispose(); pgNext = null; }
          }
          
          // Now start smooth transition to newest image
          println("[new-file] Setting up transition: imgPrev=" + img + ", imgNext=" + newestTex);
          imgPrev = img;
          imgNext = newestTex;
          transitionStart = millis();
          transitioning = true;
          newFileTransitioning = true;
          println("[new-file] Transition started! transitioning=" + transitioning + ", newFileTransitioning=" + newFileTransitioning);
          // We will start the full display interval after the fade completes
        } else {
          // No current image, just set it directly
          img = newestTex;
          println("[new-file] Set first image to newest: " + newestName);
          lastImageChange = millis();
        }
        
        currentImageIndex = 0;
      } else if (newestActuallyChanged) {
        // Texture not loaded yet OR already displayed; queue transition once loaded
        currentImageIndex = 0;
        lastImageChange = millis();
        println("[new-file] Queued newest (not loaded yet or img null): " + newestName);
      } else {
        // Newest name unchanged: do NOT reset cycle or timer
        println("[new-file] Newest unchanged (" + newestName + "). Keeping current index=" + currentImageIndex);
      }
      
      lastNewestName = newestName;
    }
  }
  
  // Queue loads for a limited window around the current index to reduce thrashing
  // Batch synchronization for better lock efficiency
  if (imageFiles != null && imageFiles.size() > 0) {
    int n = imageFiles.size();
    int window = min(PREFETCH_AHEAD, n);
    ArrayList<String> toQueue = new ArrayList<String>();
    
    // Always include the newest (index 0) so it's available for immediate transitions
    for (int k = -1; k < window; k++) {
      int idx;
      if (k == -1) {
        idx = 0; // newest
      } else {
        idx = (currentImageIndex + k) % n;
      }
      if (idx < 0) idx += n;
      String abs = imageFiles.get(idx);
      String name = new File(abs).getName();
      if (!textureCache.containsKey(name) && !toQueue.contains(abs)) {
        toQueue.add(abs);
      }
    }
    // Single synchronized batch for queue
    if (!toQueue.isEmpty()) {
      synchronized (loadQueue) {
        for (String abs : toQueue) {
          if (!loadQueue.contains(abs)) loadQueue.add(abs);
        }
      }
    }
  }

  // Remove deleted files from texture cache (single synchronized block)
  ArrayList<String> toRemove = new ArrayList<String>();
  synchronized (textureCache) {
    for (String knownName : textureCache.keySet()) {
      if (!currentNames.contains(knownName)) toRemove.add(knownName);
    }
    for (String n : toRemove) {
      textureCache.remove(n);
    }
  }

  // Ensure there's a currentImageIndex when images exist
  if ((imageFiles != null) && imageFiles.size() > 0) {
    if (currentImageIndex < 0 || currentImageIndex >= imageFiles.size()) currentImageIndex = 0;
    // if img is null or the current image is not loaded yet, queue it
    String curName = getCurrentImageName();
    if (curName != null && !textureCache.containsKey(curName)) {
      String abs = imageFiles.get(currentImageIndex);
      synchronized (loadQueue) {
        if (!loadQueue.contains(abs)) loadQueue.add(abs);
      }
    }
  }
}

void resetPoints() {
  points = new PVector[rows][cols];
  float w = width * 0.4;
  float h = height * 0.6;
  float startX = (width - w) / 2;
  float startY = (height - h) / 2;

  for (int j = 0; j < rows; j++) {
    for (int i = 0; i < cols; i++) {
      float x = map(i, 0, cols-1, startX, startX + w);
      float y = map(j, 0, rows-1, startY, startY + h);
      points[j][i] = new PVector(x, y, 0);
    }
  }
}

void draw() {
  // Poll folder periodically for changes
  if (millis() - lastPoll > POLL_INTERVAL_MS) {
    lastPoll = millis();
    pollFolderAndQueueLoads();
  }

  // Normal cycling behavior: advance every interval (but not during new-file transition)
  if (!newFileTransitioning && millis() - lastImageChange > imageChangeInterval && imageFiles != null && imageFiles.size() > 0) {
    int nextIndex = (currentImageIndex + 1) % imageFiles.size();
    String nextName = new File(imageFiles.get(nextIndex)).getName();
    int nextNum = extractNumber(nextName);
    println("[cycle] Moving from index " + currentImageIndex + " to " + nextIndex + " (" + nextName + ", num=" + nextNum + ")");
    PImage nextTex = getTexture(nextName);
    if (nextTex != null && nextTex.width > 0 && nextTex.height > 0) {
      // start transition only when we actually have a valid texture
      beginTransition(nextTex);
      currentImageIndex = nextIndex;
      lastImageChange = millis(); // update timer only on success
    } else {
      // queue load (absolute path) and try again soon without resetting timer
      String abs = imageFiles.get(nextIndex);
      synchronized (loadQueue) { if (!loadQueue.contains(abs)) loadQueue.add(abs); }
      // do not update lastImageChange so we re-attempt promptly
    }
  }
  
  background(0);
  noStroke();
  noFill();
  textureMode(IMAGE);

  // If img is null, skip texture coordinates and draw black placeholder
  if (img == null) {
    fill(0);
    rect(0,0,width,height);
    fill(255);
    textAlign(CENTER, CENTER);
    textSize(24);
    text("Waiting for textures...", width/2, height/2);
    return;
  }

  // Draw the mesh (texture mapped) with crossfade support
  if (transitioning) {
    float t = constrain((millis() - transitionStart) / (float)transitionDuration, 0, 1);
    // smoothstep easing
    t = t * t * (3 - 2 * t);

  // render previous and next into PGraphics
    // Recreate PGraphics periodically to prevent GPU context degradation
    if (pgPrev == null || pgNext == null || pgTransitionCount >= PG_RECREATE_INTERVAL) {
      if (pgPrev != null) { pgPrev.dispose(); pgPrev = null; }
      if (pgNext != null) { pgNext.dispose(); pgNext = null; }
      pgPrev = createGraphics(width, height, P3D);
      pgNext = createGraphics(width, height, P3D);
      if (pgTransitionCount >= PG_RECREATE_INTERVAL) {
        println("[GPU] Recreated PGraphics after " + pgTransitionCount + " transitions");
        pgTransitionCount = 0;
      }
    }

    drawMeshTo(pgPrev, imgPrev);
    drawMeshTo(pgNext, imgNext);

    // draw blended result
    pushStyle();
    imageMode(CORNER);
    tint(255, 255 * (1 - t));
    image(pgPrev, 0, 0);
    tint(255, 255 * t);
    image(pgNext, 0, 0);
    noTint();
    popStyle();

    if (t >= 1) {
      // finish transition
      transitioning = false;
      newFileTransitioning = false;
      img = imgNext;
      imgPrev = null;
      imgNext = null;
      if (pgPrev != null) { pgPrev.dispose(); pgPrev = null; }
      if (pgNext != null) { pgNext.dispose(); pgNext = null; }
      pgTransitionCount++; // track transitions for periodic PGraphics recreation
      // Mark start of full display period for the new image now
      lastImageChange = millis();
    }
  } else {
    // Normal single texture render
    drawMeshTo(null, img);
  }

  // Draw editable points
  if (editMode) {
    stroke(255, 50);
    for (int j = 0; j < rows; j++) {
      for (int i = 0; i < cols; i++) {
        if (i < cols - 1) line(points[j][i].x, points[j][i].y, points[j][i + 1].x, points[j][i + 1].y);
        if (j < rows - 1) line(points[j][i].x, points[j][i].y, points[j + 1][i].x, points[j + 1][i].y);
      }
    }
    noStroke();
    fill(255, 0, 0);
    for (int j = 0; j < rows; j++) {
      for (int i = 0; i < cols; i++) {
        ellipse(points[j][i].x, points[j][i].y, 10, 10);
      }
    }
  }

  if (SHOW_MEM_STATS) drawMemoryStats();
}

// Render the mesh with given texture into either the screen (if pg==null) or a PGraphics
void drawMeshTo(PGraphics pg, PImage tex) {
  PGraphics target = (pg == null) ? (PGraphics)g : pg;
  if (pg != null) {
    target.beginDraw();
    target.background(0);
    target.noStroke();
    target.textureMode(IMAGE);
  } else {
    target.noStroke();
    target.textureMode(IMAGE);
  }

  target.beginShape(QUADS);
  // Validate texture before using to prevent green screen corruption
  if (tex != null && tex.width > 0 && tex.height > 0) {
    target.texture(tex);
  } else if (tex != null) {
    println("[WARN] Invalid texture detected: width=" + tex.width + " height=" + tex.height);
    tex = null; // don't try to render invalid texture
  }
  for (int j = 0; j < rows - 1; j++) {
    for (int i = 0; i < cols - 1; i++) {
      float u1 = i / float(cols - 1);
      float v1 = j / float(rows - 1);
      float u2 = (i + 1) / float(cols - 1);
      float v2 = (j + 1) / float(rows - 1);

      PVector p1 = points[j][i];
      PVector p2 = points[j][i + 1];
      PVector p3 = points[j + 1][i + 1];
      PVector p4 = points[j + 1][i];

      target.vertex(p1.x, p1.y, p1.z, u1 * (tex != null ? tex.width : 1), v1 * (tex != null ? tex.height : 1));
      target.vertex(p2.x, p2.y, p2.z, u2 * (tex != null ? tex.width : 1), v1 * (tex != null ? tex.height : 1));
      target.vertex(p3.x, p3.y, p3.z, u2 * (tex != null ? tex.width : 1), v2 * (tex != null ? tex.height : 1));
      target.vertex(p4.x, p4.y, p4.z, u1 * (tex != null ? tex.width : 1), v2 * (tex != null ? tex.height : 1));
    }
  }
  target.endShape();

  if (pg != null) target.endDraw();
}

void beginTransition(PImage nextImg) {
  if (nextImg == null) return;
  if (transitioning) return; // ignore if already transitioning
  imgPrev = img;
  imgNext = nextImg;
  transitionStart = millis();
  transitioning = true;
  println("[transition] from " + (imgPrev==null?"<none>":"imgPrev") + " to " + (imgNext==null?"<none>":"imgNext") + " at " + transitionStart);
}

// --- Cache helpers (thread-safe) ---
// LinkedHashMap in access-order mode handles LRU automatically on get()
PImage getTexture(String name) {
  synchronized (textureCache) {
    // get() with access-order LinkedHashMap marks as most-recently used
    return textureCache.get(name);
  }
}

void putTexture(String name, PImage tex) {
  synchronized (textureCache) {
    textureCache.put(name, tex);
  }
  enforceCacheLimit();
}

void enforceCacheLimit() {
  if (MAX_CACHE_IMAGES <= 0) return;
  synchronized (textureCache) {
    // LinkedHashMap in access-order mode: oldest (least-recently used) is first
    while (textureCache.size() > MAX_CACHE_IMAGES) {
      Iterator<Map.Entry<String, PImage>> it = textureCache.entrySet().iterator();
      if (it.hasNext()) {
        it.next();
        it.remove(); // removes the least-recently used entry
      } else {
        break;
      }
    }
  }
}

// Aggressively trim cache (used after OutOfMemoryError) retaining only most recent third
void emergencyCacheTrim() {
  synchronized (textureCache) {
    int keep = textureCache.size() / 3; // keep newest third
    int toRemove = textureCache.size() - keep;
    Iterator<Map.Entry<String, PImage>> it = textureCache.entrySet().iterator();
    // LinkedHashMap in access-order mode: oldest entries are first
    // Remove the oldest (least-recently used) entries
    for (int i = 0; i < toRemove && it.hasNext(); i++) {
      it.next();
      it.remove();
    }
  }
  println("[cache] Emergency trim complete. Remaining textures: " + textureCache.size());
}

void drawMemoryStats() {
  Runtime rt = Runtime.getRuntime();
  long used = (rt.totalMemory() - rt.freeMemory()) / (1024 * 1024);
  long total = rt.totalMemory() / (1024 * 1024);
  long max = rt.maxMemory() / (1024 * 1024);
  fill(0, 160);
  noStroke();
  rect(8, 8, 320, 86);
  fill(255);
  textAlign(LEFT, TOP);
  text("Mem used: " + used + " MB\nTotal: " + total + " MB\nMax: " + max + " MB\nCache: " + textureCache.size() + "/" + MAX_CACHE_IMAGES + "\nQueue: " + loadQueue.size(), 16, 16);
}

void mousePressed() {
  if (!editMode) return;
  
  if (dragAllMode) {
    dragAllOffset.x = mouseX;
    dragAllOffset.y = mouseY;
    return;
  }
  
  for (int j = 0; j < rows; j++) {
    for (int i = 0; i < cols; i++) {
      if (dist(mouseX, mouseY, points[j][i].x, points[j][i].y) < dragThreshold) {
        draggedI = i;
        draggedJ = j;
        return;
      }
    }
  }
}

void mouseDragged() {
  if (dragAllMode) {
    float dx = mouseX - dragAllOffset.x;
    float dy = mouseY - dragAllOffset.y;
    
    for (int j = 0; j < rows; j++) {
      for (int i = 0; i < cols; i++) {
        points[j][i].x += dx;
        points[j][i].y += dy;
      }
    }
    
    dragAllOffset.x = mouseX;
    dragAllOffset.y = mouseY;
  } else if (draggedI != -1 && draggedJ != -1) {
    points[draggedJ][draggedI].x = mouseX;
    points[draggedJ][draggedI].y = mouseY;
  }
}

void mouseReleased() {
  draggedI = -1;
  draggedJ = -1;
}

void keyPressed() {
  if (key == 'r') resetPoints();
  if (key == 'e') editMode = !editMode;
  if (key == 'a') dragAllMode = !dragAllMode;

  // Save coordinates with Shift+S
  if (key == 'S') {
    saveCoordinates();
  }

  // Load coordinates with Shift+R
  if (key == 'R') {
    loadCoordinates();
  }

  // Scale mesh vertices around centroid
  if (key == '+') {
    scaleMesh(1.05); // scale up 5%
  }
  if (key == '-') {
    scaleMesh(0.95); // scale down 5%
  }
}

void saveCoordinates() {
  PrintWriter output = createWriter("mesh_coordinates.txt");
  output.println(rows + "," + cols);
  
  for (int j = 0; j < rows; j++) {
    for (int i = 0; i < cols; i++) {
      output.println(points[j][i].x + "," + points[j][i].y + "," + points[j][i].z);
    }
  }
  
  output.flush();
  output.close();
  println("Coordinates saved to mesh_coordinates.txt");
}

void loadCoordinates() {
  File f = new File(dataPath("mesh_coordinates.txt"));
  if (!f.exists()) {
    f = new File(sketchPath("mesh_coordinates.txt"));
  }
  
  if (!f.exists()) {
    println("No saved coordinates found");
    return;
  }
  
  String[] lines = loadStrings("mesh_coordinates.txt");
  if (lines.length < 1) {
    println("Invalid coordinate file");
    return;
  }
  
  String[] dimensions = split(lines[0], ',');
  int savedRows = int(dimensions[0]);
  int savedCols = int(dimensions[1]);
  
  if (savedRows != rows || savedCols != cols) {
    println("Warning: Saved dimensions don't match current mesh");
    return;
  }
  
  int lineIndex = 1;
  for (int j = 0; j < rows; j++) {
    for (int i = 0; i < cols; i++) {
      if (lineIndex < lines.length) {
        String[] coords = split(lines[lineIndex], ',');
        points[j][i].x = float(coords[0]);
        points[j][i].y = float(coords[1]);
        points[j][i].z = float(coords[2]);
        lineIndex++;
      }
    }
  }
  
  println("Coordinates loaded from mesh_coordinates.txt");
}

void scaleMesh(float factor) {
  // Compute centroid of all points
  float cx = 0, cy = 0, cz = 0;
  int count = rows * cols;
  for (int j = 0; j < rows; j++) {
    for (int i = 0; i < cols; i++) {
      cx += points[j][i].x;
      cy += points[j][i].y;
      cz += points[j][i].z;
    }
  }
  cx /= count;
  cy /= count;
  cz /= count;

  // Scale each point around centroid
  for (int j = 0; j < rows; j++) {
    for (int i = 0; i < cols; i++) {
      PVector p = points[j][i];
      p.x = cx + (p.x - cx) * factor;
      p.y = cy + (p.y - cy) * factor;
      p.z = cz + (p.z - cz) * factor;
    }
  }
}
