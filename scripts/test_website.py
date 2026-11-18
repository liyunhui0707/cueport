"""Check generated navigation, local assets and explicit download release parity."""
from html.parser import HTMLParser
import json
from pathlib import Path
import tempfile
import unittest
from build_website import build


class Links(HTMLParser):
    def __init__(self):
        super().__init__(); self.ids = set(); self.links = []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs: self.ids.add(attrs["id"])
        for key in ["src", "href"]:
            if key in attrs: self.links.append(attrs[key])


class WebsiteTests(unittest.TestCase):
    def testGeneratedSiteHasNoPlaceholderBrokenLocalLinkOrLatestAlias(self):
        with tempfile.TemporaryDirectory(prefix="aar-site-") as temporary:
            output = Path(temporary)
            facts = build(output)
            source = (output / "index.html").read_text()
            self.assertNotIn("@@", source)
            self.assertNotIn("/releases/latest", source)
            self.assertIn(facts["download_url"], source)
            self.assertIn(facts["sha256"], source)
            parsed = Links(); parsed.feed(source)
            for link in parsed.links:
                if link.startswith("#"): self.assertIn(link[1:], parsed.ids)
                elif not link.startswith("https://"): self.assertTrue((output / link).exists(), link)
            self.assertEqual(json.loads((output / "release.json").read_text()), facts)

    def testMismatchedReleaseFactsFailBeforeBuildingDownloadButton(self):
        with tempfile.TemporaryDirectory(prefix="aar-site-") as temporary:
            root = Path(temporary)
            source = Path(__file__).resolve().parent.parent / "website/release.json"
            facts = json.loads(source.read_text()); facts["download_url"] = "https://example.invalid/incorrect.zip"
            edited = root / "facts.json"; edited.write_text(json.dumps(facts))
            with self.assertRaises(ValueError): build(root / "output", edited)
            self.assertFalse((root / "output/index.html").exists())


if __name__ == "__main__": unittest.main()
