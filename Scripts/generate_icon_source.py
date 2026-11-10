#!/usr/bin/env python3
"""Qiming v2: two folded, luminous wing surfaces. No raster reference is bundled."""
from pathlib import Path
import json
root=Path(__file__).resolve().parent.parent
bundle=root/'Qiming/Resources/AppIcon.icon'
assets=bundle/'Assets'
assets.mkdir(parents=True,exist_ok=True)
# The shared mother curves are taken from the user-provided menu-bar SVG.
outer='M 3.5 3 C 2.8 8.1 5.3 9.5 10.7 10.1 C 15.7 10.7 18.5 13.1 16.1 18 C 20 13.6 18 8.5 12.3 7.4 C 7.8 6.6 4.8 7.1 3.5 3 Z'
inner='M 6 11.1 C 8 12 11.2 10.6 13.8 12.2 C 15.4 13.2 16.1 15 15.5 17.3 C 13.7 14.5 8.3 15.9 6 11.1 Z'
# Bounding box ~63% wide × 59% high, centered slightly above the canvas center.
transform='translate(36.8 80) scale(44 40)'
def svg(body):
 return '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'+body+'</svg>\n'
# A compact vector loft gives each surface a rounded cross-section. No bitmap,
# noise, filters or embedded fonts are needed. The two boundaries remain exact.
def lerp(a,b,t): return tuple(x+(y-x)*t for x,y in zip(a,b))
def split(c):
 a,b,c1,d=c
 ab=lerp(a,b,.5);bc=lerp(b,c1,.5);cd=lerp(c1,d,.5)
 abc=lerp(ab,bc,.5);bcd=lerp(bc,cd,.5);mid=lerp(abc,bcd,.5)
 return [(a,ab,abc,mid),(mid,bcd,cd,d)]
def rgb(h): return tuple(int(h[i:i+2],16) for i in [0,2,4])
def hx(c): return '#'+''.join(f'{max(0,min(255,round(x))):02X}' for x in c)
def shade(nodes,u):
 for (a,ca),(b,cb) in zip(nodes,nodes[1:]):
  if u<=b:
   t=(u-a)/(b-a);t=t*t*(3-2*t)
   return lerp(rgb(ca),rgb(cb),t)
 return rgb(nodes[-1][1])
def boundary(a,b,u): return [[lerp(x,y,u) for x,y in zip(sa,sb)] for sa,sb in zip(a,b)]
def pt(p): return f'{p[0]:.4f} {p[1]:.4f}'
def band(a,b,u0,u1):
 lo=boundary(a,b,u0);hi=boundary(a,b,u1)
 d='M '+pt(lo[0][0])
 for seg in lo:d+=' C '+' '.join(pt(p) for p in seg[1:])
 d+=' L '+pt(hi[-1][-1])
 for seg in reversed(hi):d+=' C '+' '.join(pt(p) for p in [seg[2],seg[1],seg[0]])
 return d+' Z'
def loft(a,b,nodes,y0,y1,name):
 defs=[];parts=[];count=64
 for i in range(count):
  u=(i+.5)/count;col=shade(nodes,u)
  top=hx(lerp(col,rgb('F8EEDB'),.28 if name=='silver' else .12))
  mid=hx(col)
  end=hx(lerp(col,rgb('91A7BD' if name=='silver' else 'EBC78D'),.18))
  defs.append(f'<linearGradient id="{name}{i}" gradientUnits="userSpaceOnUse" x1="0" y1="{y0}" x2="0" y2="{y1}"><stop stop-color="{top}"/><stop offset=".48" stop-color="{mid}"/><stop offset="1" stop-color="{end}"/></linearGradient>')
  path=band(a,b,max(0,i/count-.008),min(1,(i+1)/count+.008))
  parts.append(f'<path d="{path}" fill="url(#{name}{i})" stroke="url(#{name}{i})" stroke-width=".04" stroke-linejoin="round"/>')
 return '<defs>'+''.join(defs)+'</defs><g transform="'+transform+'">'+''.join(parts)+'</g>'
sa=[[(3.5,3),(4.8,7.1),(7.8,6.6),(12.3,7.4)],[(12.3,7.4),(18,8.5),(20,13.6),(16.1,18)]]
sb=[[(3.5,3),(2.8,8.1),(5.3,9.5),(10.7,10.1)],[(10.7,10.1),(15.7,10.7),(18.5,13.1),(16.1,18)]]
ga=[[(6,11.1),(8,12),(11.2,10.6),(13.8,12.2)],[(13.8,12.2),(15.4,13.2),(16.1,15),(15.5,17.3)]]
gb=split([(6,11.1),(8.3,15.9),(13.7,14.5),(15.5,17.3)])
silver_nodes=[(0,'C3CED8'),(.11,'F8F5EE'),(.34,'F1F1EC'),(.62,'D2DCE6'),(.86,'9FB2C5'),(.96,'B3C0CC'),(1,'F0E5D3')]
gold_nodes=[(0,'F4E4C8'),(.17,'CBA678'),(.46,'F0D7B2'),(.68,'F6E7CF'),(.89,'CCAB82'),(.97,'BB976E'),(1,'F1DFC5')]
outer_svg=svg(loft(sa,sb,silver_nodes,3,18,'silver'))
inner_svg=svg(loft(ga,gb,gold_nodes,11.1,17.3,'gold'))

(assets/'OuterWing.svg').write_text(outer_svg)
(assets/'InnerWing.svg').write_text(inner_svg)
for old in ['Lid.svg','Light.svg']:
 p=assets/old
 if p.exists(): p.unlink()
def gradient(top,bottom):
 def rgba(h): return 'srgb:'+','.join(f'{int(h[i:i+2],16)/255:.5f}' for i in [0,2,4])+',1.00000'
 return {'linear-gradient':[rgba(top),rgba(bottom)]}
manifest={'fill-specializations':[{'value':gradient('25374B','101B2B')},{'appearance':'dark','value':gradient('263A50','0C1421')}],
 'groups':[{'layers':[
  {'name':'香槟金内翼 · Inner light','image-name':'InnerWing.svg','glass':False,'hidden':False},
  {'name':'珍珠银外翼 · Resting wing','image-name':'OuterWing.svg','glass':False,'hidden':False}],
  'shadow':{'kind':'neutral','opacity':0},'specular':False,'translucency':{'enabled':False,'value':0}}],
 'supported-platforms':{'squares':['macOS']}}
(bundle/'icon.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
source_dir=root/'design-assets/qiming-icon-v2/source'
source_dir.mkdir(parents=True,exist_ok=True)
for name,content in [('OuterWing.svg',outer_svg),('InnerWing.svg',inner_svg)]: (source_dir/name).write_text(content)
(source_dir/'geometry.json').write_text(json.dumps({'canvas':[1024,1024],'outer':outer,'inner':inner,'transform':transform,'theme':'栖羽含光'},ensure_ascii=False,indent=2)+'\n')
print(bundle)
