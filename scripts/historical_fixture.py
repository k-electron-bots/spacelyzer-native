"""Load frozen earlier revisions of source files used as negative controls by the tests.
Fixtures live in tests/fixtures/historical as gzip files; MANIFEST.json records each file's git blob id,
and load() refuses content that does not match it."""
import gzip, hashlib, json, pathlib
D = pathlib.Path(__file__).resolve().parent.parent / 'tests' / 'fixtures' / 'historical'
def load_bytes(name):
    data = gzip.decompress((D / (name + '.gz')).read_bytes())
    want = json.loads((D / 'MANIFEST.json').read_text())[name]['git_blob_sha1']
    got = hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()
    assert got == want, f'{name}: fixture content changed ({got} != {want})'
    return data
def load(name): return load_bytes(name).decode()
