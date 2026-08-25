# Replaces the /*SG_FONT_FACE*/ token in panel.html with an @font-face rule carrying
# the editor's typeface as a data URI, so the plugin panel is set in the same face as
# the editor (docs/decisions.md: "The editor is set in Atkinson Hyperlegible") without
# the webview ever touching the network.
#
#   python3 inject_font.py <panel.html> <font.ttf|-> <out.html>
import base64
import sys

html_path, font_path, out_path = sys.argv[1:4]
html = open(html_path, encoding="utf8").read()

if font_path != "-":
    encoded = base64.b64encode(open(font_path, "rb").read()).decode()
    face = ('@font-face { font-family: "Atkinson Hyperlegible Next"; '
            'src: url(data:font/ttf;base64,' + encoded + ') format("truetype"); '
            'font-weight: 100 900; }')
    html = html.replace("/*SG_FONT_FACE*/", face)

open(out_path, "w", encoding="utf8").write(html)
