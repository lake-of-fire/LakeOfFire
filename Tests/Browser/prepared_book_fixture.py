"""Prepared native-sidecar boundary fixture, not a dictionary-processing test.

The production viewer's reveal gate requires processed m-m text or media. Raw
English paragraphs never satisfy that gate. Keep that production behavior and
provide a deterministic native-shaped chapter instead of hiding its cover.
"""
from html import escape
import json


def prepared_chapter(name):
    sentence_id = 'fixture-' + name
    text = f'This is the {name} chapter. Some content remains deliberately unmarked.'
    payload = {
        'v': 12,
        't': {
            'h': ['A1'], 'j': [], 'n': [], 's': [], 'ns': [], 'p': [],
            'x': [text], 'sid': [sentence_id], 'pid': ['paragraph-' + name],
        },
        's': [['0', 0, None, None, None, None, None, None, 0, 0, 0]],
    }
    sidecar = json.dumps(payload, separators=(',', ':'))
    return f'''<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>{escape(name)}</title><style>m-s,m-m,m-t{{display:inline}}</style></head>
<body data-is-ebook="true" data-mnb-content-fingerprint="fixture-{escape(name)}">
<p><m-s sid="{sentence_id}" h="{sentence_id}"><m-m id="mnb-s0"><m-t>{escape(text)}</m-t></m-m></m-s></p>
<script id="mnb-segment-metadata" type="application/json">{sidecar}</script>
</body></html>'''
