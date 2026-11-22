#!/usr/bin/env python3
"""Generate the bilingual Tokenory site from static copy and published release metadata."""

import argparse
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from html import escape
import json
from pathlib import Path
import re
import shutil
import subprocess
from string import Template

from site_copy import COPY


SITE = Path(__file__).resolve().parent
ROOT = SITE.parent
REPO = "https://github.com/ryekee/tokenory"
METADATA = SITE / "releases.json"
LOCALES = {"en": "/", "zh-Hans": "/zh-hans/"}
CATEGORIES = {
    "en": {"New Features": "features", "Fixes": "fixes"},
    "zh-Hans": {"新功能": "features", "修复": "fixes"},
}
ICONS = {
    name: (SITE / "icons" / f"{asset}.svg").read_text(encoding="utf-8").strip()
    .replace("<svg ", '<svg class="ui-icon" aria-hidden="true" focusable="false" ', 1)
    .replace('stroke-width="24"', 'stroke-width="20"')
    for name, asset in {
        "faq": "chat-text", "changelog": "notebook", "language": "globe",
        "download": "download-simple", "github": "github-logo", "privacy": "shield-check",
    }.items()
}


def refresh_releases(expect_tag):
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", "-H", "Accept: application/vnd.github.full+json",
         "repos/ryekee/tokenory/releases?per_page=100"],
        text=True, capture_output=True, check=True,
    )
    releases = []
    china_time = timezone(timedelta(hours=8))
    for page in json.loads(result.stdout):
        for release in page:
            tag = release["tag_name"]
            if release["draft"] or release["prerelease"] or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
                continue
            filename = f"Tokenory-{tag[1:]}-macOS-arm64.zip"
            asset = next((item for item in release["assets"] if item["name"] == filename), None)
            if not asset or not release["published_at"]:
                continue
            date = datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
            notes = published_notes(release["body"] or "")
            entry = {"tag": tag, "date": date.astimezone(china_time).date().isoformat()}
            if notes:
                entry["notes"] = notes
            else:
                # GitHub renders and sanitizes the original Markdown. The version
                # already appears in the site's heading, so omit duplicate titles.
                original = (release["body_html"] or "").removeprefix(f"<h1>Tokenory {tag[1:]}</h1>").strip()
                entry["original_html"] = re.sub(r"<(/?)h[12]>", r"<\1h3>", original)
            releases.append(entry)

    releases.sort(key=lambda item: tuple(map(int, item["tag"][1:].split("."))), reverse=True)
    if not releases or (expect_tag and not any(item["tag"] == expect_tag for item in releases)):
        raise ValueError("Could not find the expected public Tokenory release")
    latest = subprocess.check_output(
        ["gh", "api", "repos/ryekee/tokenory/releases/latest", "--jq", ".tag_name"], text=True,
    ).strip()
    if releases[0]["tag"] != latest:
        raise ValueError(f"Newest Mac release does not match GitHub Latest: {latest}")
    METADATA.write_text(json.dumps(releases, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def published_notes(body):
    """Read the bilingual release format, including historical upgrade guidance."""
    languages = {"English": "en", "简体中文": "zh-Hans"}
    notes = {lang: {"features": [], "fixes": []} for lang in LOCALES}
    language = None
    category = None
    for line in body.splitlines():
        if line.startswith("## "):
            language = languages.get(line[3:])
            category = None
        elif language and line.startswith("### "):
            category = CATEGORIES[language].get(line[4:])
        elif category and line.startswith("- "):
            notes[language][category].append(line[2:])
        elif category and line.strip():
            notes[language].setdefault("paragraphs", []).append(line.strip())
    return notes if all(sections["features"] or sections["fixes"] for sections in notes.values()) else None


def download(tag):
    return f"{REPO}/releases/download/{tag}/Tokenory-{tag[1:]}-macOS-arm64.zip"


def nav_link(href, label, icon, *, current=None, footer=False):
    active = ' aria-current="page"' if href == current else ""
    text_class = ' class="dock-label"' if footer else ""
    return f'<a href="{href}" aria-label="{escape(label)}"{active}>{ICONS[icon]}<span{text_class}>{escape(label)}</span></a>'


def demo_prices():
    data = ROOT / "cli/tokenory/data"
    remote = json.loads((data / "remote-pricing.json").read_text(encoding="utf-8"))
    openai = {item["model"]: item["standard"] for item in remote["entries"] if item["provider"] == "openai"}
    catalog = json.loads((data / "price-catalog.json").read_text(encoding="utf-8"))
    sonnet = next(item["rates"] for item in catalog
                  if (item["provider"], item["model"]) == ("anthropic", "claude-sonnet-4-6"))
    return [
        {"name": "GPT-6.2 Astra", **{key: openai["gpt-6.2-astra"][key] for key in ("input", "output")}},
        {"name": "GPT-6.2 Sol", **{key: openai["gpt-6.2-sol"][key] for key in ("input", "output")}},
        {"name": "Claude Sonnet 4.6", "input": sonnet["input_cost_per_token"] * 1_000_000,
         "output": sonnet["output_cost_per_token"] * 1_000_000},
    ]


def feature_showcases(copy, models):
    priced, timed, private = copy["features"]
    title = copy["features_title"]
    heading = escape(title) if isinstance(title, str) else "<wbr>".join(f"<span>{escape(part)}</span>" for part in title)
    estimates = [(model["name"], model["input"] * inputs + model["output"] * outputs)
                 for model, (inputs, outputs) in zip(models, [(3, .3), (8, .3), (4, .2)])]
    max_estimate = max(amount for _, amount in estimates)
    cost_rows = "".join(
        f'<li><span>{escape(name)}</span><span class="bar" aria-hidden="true"><i style="--share:{amount / max_estimate:.1%}"></i></span>'
        f'<strong>${amount:.2f}</strong></li>' for name, amount in estimates
    )
    speed_rows = "".join(f'<div><dt>{escape(label)}</dt><dd>{time:g} s</dd></div>'
                         for label, time in zip(copy["speed_labels"], [1.4, 8.2, 12.8]))
    return f"""
<section class="features">
  <h2>{heading}</h2>
  <div class="showcases">
    <article>
      <figure class="showcase">
        <figcaption>{escape(copy['cost_example'])} <small>{escape(copy['sample'])}</small></figcaption>
        <ul class="example-costs">{cost_rows}</ul>
      </figure>
      <h3>{escape(priced[0])}</h3><p>{escape(priced[1])}</p>
    </article>
    <article>
      <figure class="showcase">
        <figcaption>{escape(copy['speed_example'])} <small>{escape(copy['sample'])}</small></figcaption>
        <dl class="example-turn">{speed_rows}</dl>
        <div class="example-timeline" aria-hidden="true"><i></i><i></i><i></i></div>
      </figure>
      <h3>{escape(timed[0])}</h3><p>{escape(timed[1])}</p>
    </article>
  </div>
  <article class="local-ledger">
    {ICONS['privacy']}
    <div><h3>{escape(private[0])}</h3><p>{escape(private[1])}</p></div>
  </article>
</section>
"""


def home(copy, tag, models):
    first, second = copy["headline"]
    emphasis = copy["headline_emphasis"]
    before, after = second.split(emphasis, 1)
    headline = f"<span>{escape(first)}</span> <span>{escape(before)}<em>{escape(emphasis)}</em>{escape(after)}</span>"
    digits = "".join(
        '<span class="punct">,</span>' if digit == "," else
        f'<span class="drum"><span class="drum-track"><span>{digit}</span></span></span>'
        for digit in "128,648"
    )
    return f"""
<section class="hero">
  <div class="intro">
    <h1>{headline}</h1>
    <p>{escape(copy['intro'])}</p>
    <div class="download-row">
      <a class="download" href="{download(tag)}">{ICONS['download']}{escape(copy['download'])}</a>
      <p class="requirements">{tag} · {escape(copy['requirements'])}</p>
    </div>
  </div>
  <figure class="stage" aria-label="{escape(copy['demo'])}">
    <div class="counter">
      <div class="bezel">
        <div class="readout" aria-hidden="true">{digits}</div>
        <output class="sr-only" aria-live="polite">128,648 {escape(copy['tokens'])}</output>
      </div>
      <div class="hardware" hidden>
        <div class="metric-buttons">
          <button type="button" aria-label="{escape(copy['tokens'])}" title="{escape(copy['tokens'])}" aria-pressed="true" data-metric="tokens">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4H4v16h3M17 4h3v16h-3M9 8h6M9 12h4M9 16h6"/></svg>
          </button>
          <button type="button" aria-label="{escape(copy['cost'])}" title="{escape(copy['cost'])}" aria-pressed="false" data-metric="cost">
            <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M15 8.5c-1.1-1.1-5-1.2-5 1s5 1.7 5 4-3.7 2.6-6 1M12 6v12"/></svg>
          </button>
        </div>
        <span class="grille" aria-hidden="true"></span>
        <button class="sound-button" type="button" aria-label="{escape(copy['sound'])}" title="{escape(copy['sound'])}" aria-pressed="false">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4Z"/><path class="sound-waves" d="M15 8c2 2 2 6 0 8 M18 5c4 4 4 10 0 14"/><path class="sound-muted" d="m15 10 5 5m0-5-5 5"/></svg>
        </button>
      </div>
    </div>
    <div class="hud-flight-layer" aria-hidden="true"></div>
    <button class="run-counter" type="button" data-models="{escape(json.dumps(models, ensure_ascii=False))}"
      data-done="{escape(copy['hud_done'])}" data-input="{escape(copy['hud_input'])}" data-output="{escape(copy['hud_output'])}"
      hidden>{escape(copy['run_counter'])}</button>
    <figcaption>{escape(copy['sample'])}</figcaption>
  </figure>
</section>
{feature_showcases(copy, models)}
"""


def faqs(copy):
    entries = []
    for index, (question, answer) in enumerate(copy["questions"]):
        source = (f'<a href="{REPO}/blob/main/docs/local/sources.md">{escape(copy["sources"])}</a>'
                  if index == 1 else "")
        entries.append(f"<details><summary>{escape(question)}</summary><p>{escape(answer)}</p>{source}</details>")
    return f'<section class="reading"><h1>{escape(copy["faq"])}</h1>{"".join(entries)}</section>'


def changelog(copy, language, releases):
    entries = []
    for release in releases:
        tag, date = release["tag"], release["date"]
        sections = []
        notes = release.get("notes", {}).get(language, {})
        for category, heading in (("features", copy["new_header"]), ("fixes", copy["fix_header"])):
            if notes.get(category):
                items = "".join(f"<li>{escape(item)}</li>" for item in notes[category])
                sections.append(f"<h3>{escape(heading)}</h3><ul>{items}</ul>")
        sections.extend(f"<p>{escape(paragraph)}</p>" for paragraph in notes.get("paragraphs", []))
        body = "".join(sections) or release.get("original_html", "")
        entries.append(
            f'<article class="release" id="{tag}"><header><h2><a href="{REPO}/releases/tag/{tag}">{tag}</a></h2>'
            f'<time datetime="{date}">{date}</time></header><div class="release-notes">{body}</div></article>'
        )
    return f'<section class="reading"><h1>{escape(copy["changelog"])}</h1>{"".join(entries)}</section>'


def build():
    releases = json.loads(METADATA.read_text(encoding="utf-8"))
    latest = releases[0]["tag"]
    models = demo_prices()
    dist = SITE / "dist"
    assets = dist / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    (dist / ".assetsignore").write_text(".DS_Store\n", encoding="utf-8")
    asset_urls = {}
    for name in ("style.css", "demo.js"):
        contents = (SITE / name).read_bytes()
        (assets / name).write_bytes(contents)
        asset_urls[name] = f"/assets/{name}?v={sha256(contents).hexdigest()[:12]}"
    shutil.copyfile(ROOT / "assets/brand/app-icon.png", assets / "app-icon.png")
    shutil.copyfile(SITE / "icons/LICENSE.txt", assets / "Phosphor-LICENSE.txt")
    for name in ("mechanical-digits.ttf", "SairaExtraCondensed-OFL.txt"):
        shutil.copyfile(SITE / "fonts" / name, assets / name)
    template = Template((SITE / "page.html").read_text(encoding="utf-8"))

    for language, base in LOCALES.items():
        copy = COPY[language]
        alternate = next(lang for lang in LOCALES if lang != language)
        pages = {
            "": ("Tokenory", home(copy, latest, models)),
            "faqs/": (copy["faq"], faqs(copy)),
            "changelog/": (copy["changelog"], changelog(copy, language, releases)),
        }
        for page, (title, content) in pages.items():
            route = base + page
            path = dist / route.lstrip("/") / "index.html"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(template.substitute(
                language=language, title=f"{title} · Tokenory" if page else "Tokenory · " + escape(copy["intro"]),
                description=escape(copy["intro"]), base=base, nav_label=escape(copy["nav"]),
                faq=nav_link(base + "faqs/", copy["faq"], "faq", current=route),
                changelog=nav_link(base + "changelog/", copy["changelog"], "changelog", current=route),
                footer_label=escape(copy["footer_nav"]),
                footer_faq=nav_link(base + "faqs/", copy["faq"], "faq", footer=True),
                footer_changelog=nav_link(base + "changelog/", copy["changelog"], "changelog", footer=True),
                footer_github=nav_link(REPO, "GitHub", "github", footer=True),
                alternate_link=LOCALES[alternate] + page, alternate_language=alternate,
                alternate_label=escape(copy["switch"]), content=content,
                language_icon=ICONS["language"], download_icon=ICONS["download"],
                download_url=download(latest), download_label=escape(copy["nav_download"]),
                stylesheet=asset_urls["style.css"],
                script=f'<script type="module" src="{asset_urls["demo.js"]}"></script>' if not page else "",
            ), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh-releases", action="store_true", help="Refresh public GitHub release metadata before building")
    parser.add_argument("--expect-tag", default="")
    args = parser.parse_args()
    if args.refresh_releases:
        refresh_releases(args.expect_tag)
    build()


if __name__ == "__main__":
    main()
