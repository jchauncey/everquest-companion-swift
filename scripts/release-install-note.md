
## Install

Download the `.zip` below, unzip it, and drag **EQCompanion.app** into `/Applications`.

This build is **ad-hoc signed and not notarized**, so macOS quarantines anything downloaded from
the internet and will claim the app "is damaged and can't be opened". It is not damaged — that is
what the quarantine flag looks like on an app Apple has not notarized. Clear it once:

```sh
xattr -dr com.apple.quarantine /Applications/EQCompanion.app
```

Then open it normally. Building from source needs no such step, because the signature is made on
your own machine:

```sh
git clone https://github.com/jchauncey/everquest-companion-swift.git
cd everquest-companion-swift
make install
```

Requires macOS 14+ and EverQuest Legends under CrossOver, Whisky or Wine. In game, type `/log on` —
the app reads that log file and nothing else.
