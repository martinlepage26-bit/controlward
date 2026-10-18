import cairosvg
from PIL import Image, ImageDraw, ImageFont
T='#4CEFF5';G='#F5AF55';W='#FFFFFF';BG='#041522'
def mark(sw=9):
  return f'''<g fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-width="{sw}">
<line x1="146" y1="64" x2="146" y2="136" stroke="#EAF8FA"/><line x1="146" y1="152" x2="146" y2="228" stroke="{T}"/>
<line x1="62" y1="144" x2="138" y2="144" stroke="{T}"/><line x1="154" y1="144" x2="226" y2="144" stroke="#F2FBFC"/>
<circle cx="146" cy="53" r="11" stroke="{T}"/><circle cx="146" cy="239" r="11" stroke="{T}"/><circle cx="51" cy="144" r="11" stroke="{T}"/><circle cx="237" cy="144" r="11" stroke="#F2FBFC"/>
<path d="M72 86 Q72 64 88 64 Q96 64 99 70" stroke="{T}"/><path d="M99 70 Q106 76 110 90" stroke="{G}"/>
<path d="M190 91 Q190 64 206 64 Q222 64 221 84 L217 120" stroke="{T}"/>
<line x1="168" y1="114" x2="187" y2="101" stroke="{G}" stroke-width="11"/>
<line x1="106" y1="99" x2="122" y2="119" stroke="{W}"/>
<line x1="75" y1="166" x2="80" y2="186" stroke="{T}" stroke-width="10"/>
<line x1="101" y1="190" x2="118" y2="171" stroke="{G}" stroke-width="10"/>
<path d="M86 197 Q72 202 74 214 Q77 222 96 222" stroke="{G}" stroke-width="10"/><path d="M103 204 Q104 220 114 230" stroke="{G}" stroke-width="10"/>
<line x1="173" y1="168" x2="189" y2="189" stroke="{G}" stroke-width="10"/>
<g stroke="{W}" stroke-width="10"><line x1="210" y1="192" x2="221" y2="166"/><line x1="203" y1="172" x2="216" y2="168"/>
<circle cx="187" cy="214" r="9"/><circle cx="211" cy="214" r="7"/><line x1="196" y1="214" x2="204" y2="214"/><line x1="177" y1="200" x2="180" y2="205"/><line x1="181" y1="223" x2="178" y2="230"/></g>
<circle cx="146" cy="144" r="10" fill="{BG}" stroke="#F4F1E8" stroke-width="6"/>
<g stroke="none"><circle cx="74" cy="110" r="8" fill="{G}"/><circle cx="217" cy="111" r="7" fill="{T}"/><circle cx="146" cy="144" r="3.5" fill="{G}"/></g></g>'''
def mark_small(sw=14):
  return f'''<g fill="none" stroke-linecap="round" stroke-width="{sw}"><line x1="146" y1="70" x2="146" y2="218" stroke="{T}"/><line x1="70" y1="144" x2="222" y2="144" stroke="{T}"/>
<g stroke="{T}"><circle cx="146" cy="56" r="14"/><circle cx="146" cy="232" r="14"/><circle cx="56" cy="144" r="14"/><circle cx="236" cy="144" r="14"/></g>
<circle cx="146" cy="144" r="16" fill="{G}" stroke="{W}" stroke-width="8"/></g>'''
def svg(body,vb='30 30 232 232',w=1024,h=1024,bg=''):
  return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{w}" height="{h}">{bg}{body}</svg>'
open('controlward-mark.svg','w').write(svg(mark()))
sq=f'<rect x="30" y="30" width="232" height="232" rx="52" fill="{BG}"/>'
open('controlward-icon.svg','w').write(svg('<g transform="translate(146 146) scale(.8) translate(-146 -146)">'+mark()+'</g>',bg=sq))
for n in (1024,512):
  cairosvg.svg2png(url='controlward-mark.svg',write_to=f'controlward-mark-{n}.png',output_width=n,output_height=n)
  cairosvg.svg2png(url='controlward-icon.svg',write_to=f'controlward-icon-{n}.png',output_width=n,output_height=n)
# lockup
lk=f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 300" width="1800" height="600">
<rect width="900" height="300" rx="24" fill="{BG}"/>
<g transform="translate(20 4) scale(1)"><g transform="translate(-30 -0)">{mark()}</g></g>
<text x="290" y="160" font-family="Helvetica, Arial, sans-serif" font-weight="700" font-size="92" fill="{W}">Control<tspan fill="{G}">Ward</tspan></text>
<text x="400" y="222" font-family="Helvetica, Arial, sans-serif" font-size="34" letter-spacing="7" fill="#C9D3DC">PHAROS CRM</text></svg>'''
open('controlward-lockup.svg','w').write(lk)
cairosvg.svg2png(url='controlward-lockup.svg',write_to='controlward-lockup.png')
# comparison
src=Image.open('../crop-sidebar-mark.png').convert('RGB').resize((600,600))
cairosvg.svg2png(bytestring=svg(mark(),vb='0 0 300 300',w=600,h=600,bg=f'<rect width="300" height="300" fill="{BG}"/>').encode(),write_to='/tmp/r.png')
r=Image.open('/tmp/r.png').convert('RGB')
ov=Image.blend(src,r,.5)
cmp=Image.new('RGB',(1800,640),'white');d=ImageDraw.Draw(cmp)
for i,(im,t) in enumerate([(src,'mockup (sidebar crop, 2x)'),(r,'redraw (vector)'),(ov,'50% overlay')]):
  cmp.paste(im,(i*600,40));d.text((i*600+10,10),t,fill='black')
cmp.save('comparison-mockup-vs-redraw.png')
src4=Image.open('../crop-sidebar-mark.png').convert('RGB').resize((1200,1200),Image.LANCZOS)
cairosvg.svg2png(bytestring=svg(mark(),vb='0 0 300 300',w=1200,h=1200,bg=f'<rect width="300" height="300" fill="{BG}"/>').encode(),write_to='/tmp/r4.png')
Image.blend(src4,Image.open('/tmp/r4.png').convert('RGB'),.5).crop((150,150,1050,1050)).save('overlay-4x.png')
open('controlward-icon-small.svg','w').write(svg(mark_small(),bg=sq))
for n in (16,32,64):cairosvg.svg2png(url='controlward-icon-small.svg',write_to=f'controlward-icon-small-{n}.png',output_width=n,output_height=n)
sm=Image.new('RGB',(240,60),'#2a2f36')
for i,f in enumerate(['controlward-icon-small-16.png','controlward-icon-small-32.png','controlward-icon-16full.png']):
  pass
ic=Image.open('controlward-icon-1024.png')
for i,(im,x) in enumerate([(Image.open('controlward-icon-small-16.png'),10),(Image.open('controlward-icon-small-32.png'),40),(ic.resize((16,16),Image.LANCZOS),110),(ic.resize((32,32),Image.LANCZOS),140)]):sm.paste(im,(x,10),im)
sm.resize((800,240),Image.NEAREST).save('legibility-16-32.png')
