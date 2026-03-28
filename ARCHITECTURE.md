# silex-packages Architecture

## Package Management: Three-List System

The build system uses **three independent lists** to manage 516 Debian packages, each with a single responsibility.

### Lists

#### 1. `config/skip.list` — CI Management
**Purpose:** Packages to exclude from the build closure.

- **In:** Base image (silex:slim), so don't recompile
- **Effect:** Filtered from closure before classification (performance + safety)
- **Note:** Packages here may still appear in final repo via `required-repo.list`

**Examples:** bash, coreutils, gcc, g++, make (already in base image)

#### 2. `config/repack-override.list` — Classification Override
**Purpose:** Force repacking instead of recompilation.

- **In:** Packages with .so files where repacking is better than compiling
- **Effect:** Affects classification decision (repack vs recompile), not filtering
- **Independent:** Works regardless of skip.list or required-repo.list

**Examples:** libtbb-dev (300+ test targets), llvm-tools (version conflicts)

#### 3. `config/required-repo.list` — Repository Guarantee
**Purpose:** Packages that MUST be in the final APK repository.

- **In:** Critical packages needed by users, even if in skip.list
- **Effect:** Added to repack.list AFTER classification (overrides skip.list filtering)
- **Use case:** build-essential metapackage depends on unversioned gcc, g++, make

**Examples:** gcc, g++, make, binutils, libc6-dev

### Data Flow

```
Resolve Closure (516 packages)
    ↓
Filter skip.list (−58 packages)
    ↓
Classify → Recompile (244) + Repack (214)
    ↓
Add required-repo.list (+5 packages)
    ↓
Final: Recompile (244) + Repack (219)
```

### Design Principles

**Separation of Concerns:**
- skip.list → CI environment protection (build-time)
- repack-override.list → Compilation strategy (build-time)
- required-repo.list → Repository content (post-build)

**Single Responsibility:**
- Each list has ONE clear job
- No conceptual overlap
- Easy to understand and maintain

**Explicit Intent:**
- File names state purpose clearly
- Comments explain the why, not just the what
- Architecture is self-documenting

### Example: gcc, g++, make

**Problem:** build-essential metapackage depends on unversioned gcc, g++, make.

**Solution:**
- Listed in skip.list (already in silex:slim base image → no need to rebuild during CI)
- Added to required-repo.list (end users of the repo need them for build-essential)
- Prep.sh adds them to repack.list despite skip.list filtering

**Result:** Build tools protected during CI, available to users in final repository.

### Adding New Packages

**To skip during CI:** Add to `config/skip.list`
```sh
# Skip this package - it's in the base image
new-package
```

**To force repacking:** Add to `config/repack-override.list`
```sh
# Has .so files but repacking is cheaper than recompiling
new-package
```

**To require in repo:** Add to `config/required-repo.list`
```sh
# Critical for users despite being in skip.list
new-package
```

**Multiple lists:** Package can be in multiple lists. Order of precedence:
1. skip.list filters first (closure management)
2. Classification decides repack vs recompile
3. required-repo.list adds back to ensure presence in repo
