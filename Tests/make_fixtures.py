"""Generate disposable synthetic EPUBs; no downloads or personal books."""
from pathlib import Path
import io
import struct
import sys
import zipfile

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
DC = 'xmlns:dc="http://purl.org/dc/elements/1.1/"'
container = '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'

def opf(title='A Test Book', isbn='9780306406157', extra='', version='3.0', href='chapter.xhtml', authors='<dc:creator>Ada Author</dc:creator>'):
    return f'''<package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="{version}"><metadata {DC}>
    <dc:title>{title}</dc:title>{authors}<dc:identifier>{isbn}</dc:identifier>
    <dc:publisher>Test Press</dc:publisher><dc:date>2024-01-02</dc:date>{extra}
    </metadata><manifest><item id="ch" href="{href}" media-type="application/xhtml+xml"/>
    <item id="font" href="font.otf" media-type="font/otf"/></manifest><spine><itemref idref="ch"/></spine></package>'''

def chapter(text='Synthetic book content.'):
    return f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head><body><p>{text}</p></body></html>'

def entries(package=None, body=None):
    return [('mimetype', b'application/epub+zip'), ('META-INF/container.xml', container),
            ('OPS/book.opf', opf() if package is None else package),
            ('OPS/chapter.xhtml', chapter() if body is None else body), ('OPS/font.otf', b'font')]

def write(name, items=None, compression=zipfile.ZIP_DEFLATED, descriptor=False):
    class NonSeekable(io.BytesIO):
        def seekable(self): return False
        def seek(self, *args): raise io.UnsupportedOperation()
    buffer = NonSeekable() if descriptor else io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=compression) as archive:
        for path, data in entries() if items is None else items:
            archive.writestr(path, data, compress_type=zipfile.ZIP_STORED if path == 'mimetype' else compression)
    (out / name).write_bytes(buffer.getvalue())

write('metadata.epub')
write('stored.EPUB', compression=zipfile.ZIP_STORED)
write('descriptor.epub', descriptor=True)
write('epub2.epub', entries(opf(title='Élan &amp; Space', isbn='urn:isbn:0-306-40615-2', version='2.0',
    authors='<dc:creator opf:role="aut">Zoë Author</dc:creator><dc:creator opf:role="edt">Ed Editor</dc:creator>')))
write('refined.epub', entries(opf(title='Alternative title', extra='<dc:title id="main">Main Title</dc:title><meta refines="#main" property="title-type">main</meta><meta refines="#editor" property="role">edt</meta>', authors='<dc:creator>Ada Author</dc:creator><dc:creator id="editor">Ed Editor</dc:creator>')))
write('title-only.epub', entries(opf(isbn='urn:uuid:1234')))
write('body-isbn.epub', entries(opf(title='', isbn='urn:uuid:1234'), chapter('ISBN: <span>9780306</span>406157. LCCN: 2024123456')))
write('Writer - A Filename Book.epub', entries(opf(title='', isbn='')))
write('9780306406157.epub', entries(opf(title='', isbn='')))
write('ignore-scripts.epub', entries(opf(isbn=''), '<html><head><title>ISBN: 9780306406157</title></head><body><script>ISBN: 9780306406157</script><style>ISBN: 9780306406157</style><p>No number.</p></body></html>'))
write('encoded-path.epub', [(k if k != 'OPS/chapter.xhtml' else 'OPS/text chapter.xhtml', v) for k,v in entries(opf(isbn='', href='text%20chapter.xhtml'), chapter('ISBN: 9780306406157'))])
write('parent-path.epub', [(k if k != 'OPS/chapter.xhtml' else 'chapter.xhtml', v) for k,v in entries(opf(isbn='', href='../chapter.xhtml'), chapter('ISBN: 9780306406157'))])
utf16 = entries()
utf16[2] = ('OPS/book.opf', ('<?xml version="1.0" encoding="UTF-16"?>' + opf(title='UTF16 Title')).encode('utf-16'))
write('utf16.epub', utf16)
write('large-chapter.epub', entries(opf(isbn=''), chapter('a' * (2*1024*1024 + 1))))
write('external-dtd.epub', entries(body='<!DOCTYPE html SYSTEM "https://invalid.example/never-fetch.dtd">' + chapter('ISBN: 9780306406157'), package=opf(isbn='')))
write('remote-resource.epub', entries(opf(isbn='', href='https://invalid.example/never-fetch.xhtml')))
encryption = '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><EncryptionMethod Algorithm="{algorithm}"/><CipherData><CipherReference URI="{uri}"/></CipherData></EncryptedData></encryption>'
write('font-obfuscated.epub', entries() + [('META-INF/encryption.xml', encryption.format(algorithm='http://www.idpf.org/2008/embedding', uri='OPS/font.otf'))])
write('drm.epub', entries() + [('META-INF/encryption.xml', encryption.format(algorithm='http://www.w3.org/2001/04/xmlenc#aes128-cbc', uri='OPS/chapter.xhtml'))])
write('fake-font.epub', entries() + [('META-INF/encryption.xml', encryption.format(algorithm='http://www.idpf.org/2008/embedding', uri='OPS/chapter.xhtml'))])
write('rights.epub', entries() + [('META-INF/rights.xml', '<rights/>')])
write('traversal.epub', entries() + [('../escape', 'bad')])
write('absolute.epub', entries() + [('/tmp/escape', 'bad')])
write('href-escape.epub', entries(opf(href='../../escape')))
write('encoded-escape.epub', entries(opf(href='%2e%2e/%2e%2e/escape')))
write('duplicate.epub', entries() + [('OPS/book.opf', opf(title='Wrong'))])
link = zipfile.ZipInfo('OPS/link'); link.create_system = 3; link.external_attr = 0o120777 << 16
write('symlink.epub', entries() + [(link, '/tmp/escape')])
write('entities.epub', entries('<!DOCTYPE package [<!ENTITY x "expanded">]>' + opf(title='&x;')))
write('entities-utf16.epub', entries(('<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE package [<!ENTITY x "expanded">]>' + opf(title='&x;')).encode('utf-16')))
write('deep-xml.epub', entries(opf(extra='<meta>' * 65 + 'deep' + '</meta>' * 65)))
write('many-nodes.epub', entries(opf(extra='<x/>' * 50_001)))
write('malformed-xml.epub', entries('<package>'))
write('oversize-metadata.epub', entries(opf(title='a' * (1024*1024 + 1))))
write('unsupported-zip.epub', compression=zipfile.ZIP_BZIP2)
write('missing-package.epub', [(k,v) for k,v in entries() if k != 'OPS/book.opf'])
write('wrong-mimetype.epub', [(k, 'text/plain' if k == 'mimetype' else v) for k,v in entries()])
(out / 'not-zip.epub').write_bytes(b'not a ZIP')

original = (out / 'metadata.epub').read_bytes()
def modify_entry(name, fn):
    data = bytearray(original)
    position = 0
    while (position := data.find(b'PK\x01\x02', position)) >= 0:
        n = struct.unpack_from('<H', data, position+28)[0]
        if data[position+46:position+46+n] == b'OPS/book.opf':
            local = struct.unpack_from('<I', data, position+42)[0]
            fn(data, position, local)
            break
        position += 4
    (out/name).write_bytes(data)
modify_entry('encrypted-zip.epub', lambda d,c,l: (struct.pack_into('<H', d,c+8,1), struct.pack_into('<H', d,l+6,1)))
modify_entry('bad-crc.epub', lambda d,c,l: (struct.pack_into('<I',d,c+16,0),struct.pack_into('<I',d,l+14,0)))
modify_entry('lying-size.epub', lambda d,c,l: (struct.pack_into('<I',d,c+24,1),struct.pack_into('<I',d,l+22,1)))
modify_entry('declared-bomb.epub', lambda d,c,l: (struct.pack_into('<I',d,c+24,33*1024*1024),struct.pack_into('<I',d,l+22,33*1024*1024)))
modify_entry('bad-offset.epub', lambda d,c,l: struct.pack_into('<I', d,c+42,0xfffffffe))
modify_entry('local-mismatch.epub', lambda d,c,l: struct.pack_into('<H', d,l+8,0))
zip64 = bytearray(original); end=zip64.rfind(b'PK\x05\x06'); struct.pack_into('<HH',zip64,end+8,65535,65535)
(out/'zip64.epub').write_bytes(zip64)
(out/'truncated.epub').write_bytes(original[:-12])
# Sparse oversized input tests the archive cap without storing a large fixture in Git.
with (out/'oversize-archive.epub').open('wb') as handle:
    handle.truncate(128*1024*1024+1)
print('Generated synthetic EPUB fixtures in', out)
