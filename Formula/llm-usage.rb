# Tap this repository directly — it has no `homebrew-` prefix, so the URL is
# explicit:
#
#   brew tap simota/llm-usage https://github.com/simota/llm-usage
#   brew install llm-usage
#
# A formula rather than a cask, deliberately: casks quarantine what they install
# and Homebrew has removed every way to opt out, so a cask of an app that is not
# Developer ID signed and notarised cannot be opened at all. Formula downloads
# are not quarantined, and the ad-hoc signature the build applies is enough for
# macOS to execute it.
#
# `version`, `url` and `sha256` are rewritten by .github/workflows/release.yml on
# every tag; there is no need to edit them by hand.
class LlmUsage < Formula
  desc "Menu bar app tracking Claude Code, Codex CLI and Antigravity usage limits"
  homepage "https://github.com/simota/llm-usage"
  url "https://github.com/simota/llm-usage/releases/download/v0.2.0/LLMUsage-0.2.0.zip"
  version "0.2.0"
  sha256 "7c413f5598990dc979ff4e5f054f8caf822b2eff2d5c60d5f3102560775629b6"

  # Matches LSMinimumSystemVersion in packaging/Info.plist.
  depends_on macos: :ventura

  def install
    prefix.install "LLMUsage.app"
    # The bundle is the product, but --probe and --panel are the only way to
    # check the data plumbing without clicking the menu bar, so expose them.
    (bin/"llm-usage").write <<~SH
      #!/bin/sh
      exec "#{opt_prefix}/LLMUsage.app/Contents/MacOS/LLMUsage" "$@"
    SH
  end

  service do
    run [opt_prefix/"LLMUsage.app/Contents/MacOS/LLMUsage"]
    keep_alive true
    log_path var/"log/llm-usage.log"
    error_log_path var/"log/llm-usage.log"
  end

  def caveats
    <<~EOS
      LLM Usage lives in the menu bar and has no window or Dock icon.

      Start it now and at every login:
        brew services start llm-usage

      Or run it once, without launchd:
        open #{opt_prefix}/LLMUsage.app

      To reach it from Spotlight and Launchpad:
        ln -sfn #{opt_prefix}/LLMUsage.app /Applications/LLMUsage.app

      Each source authenticates on its own: Claude Code needs a login (the app
      reads its keychain item and macOS will ask once per version), Codex needs
      ~/.codex/auth.json, and Antigravity needs `agy` running.
    EOS
  end

  test do
    # The signature surviving the zip round trip is the thing most likely to
    # break, and an arm64 binary without one cannot run at all.
    system "codesign", "--verify", "--strict", prefix/"LLMUsage.app"
    assert_path_exists prefix/"LLMUsage.app/Contents/MacOS/LLMUsage"
  end
end
