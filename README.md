# Platform

Apple frameworks the v57 apps need, reimplemented behind one API per feature. Each `Platform<Feature>` library uses
the Apple framework on Apple platforms and the platform's own elsewhere (Linux, Windows, Android), so apps stay free
of `#if os` and Apple-only imports. `PlatformKit` says which platform a build runs on.
