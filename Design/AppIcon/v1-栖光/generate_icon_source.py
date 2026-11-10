#!/usr/bin/env python3
"""Author the three-layer Qiming icon from the approved geometry, without dependencies."""
from pathlib import Path
import json
root=Path(__file__).resolve().parent.parent
bundle=root/'Qiming/Resources/AppIcon.icon'
assets=bundle/'Assets'
assets.mkdir(parents=True,exist_ok=True)
svg='''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>\n'''
bar='''<defs><linearGradient id="silver" x1="0" y1="418" x2="0" y2="482" gradientUnits="userSpaceOnUse"><stop stop-color="#F1F3EF"/><stop offset=".34" stop-color="#C4D0D0"/><stop offset=".78" stop-color="#B5C4C9"/><stop offset="1" stop-color="#94A6AE"/></linearGradient></defs><rect x="242" y="418" width="540" height="64" rx="32" fill="url(#silver)"/><rect x="242.5" y="418.5" width="539" height="63" rx="31.5" fill="none" stroke="#F7F8F4" stroke-opacity=".38"/>'''
core='''<defs><radialGradient id="halo"><stop stop-color="#D8B878" stop-opacity=".13"/><stop offset=".736842" stop-color="#D8B878" stop-opacity=".10"/><stop offset="1" stop-color="#D8B878" stop-opacity="0"/></radialGradient><radialGradient id="gold" gradientUnits="userSpaceOnUse" cx="512" cy="580" r="73" fx="494" fy="559"><stop stop-color="#F2DCAF"/><stop offset=".62" stop-color="#D8B878"/><stop offset="1" stop-color="#B88B48"/></radialGradient></defs><circle cx="512" cy="580" r="76" fill="url(#halo)"/><circle cx="512" cy="580" r="56" fill="url(#gold)"/>'''
(assets/'Lid.svg').write_text(svg.format(body=bar))
(assets/'Light.svg').write_text(svg.format(body=core))
def gradient(top,bottom):
 def rgba(h):
  return 'srgb:'+','.join(f'{int(h[i:i+2],16)/255:.5f}' for i in [0,2,4])+',1.00000'
 return {'linear-gradient':[rgba(top),rgba(bottom)],'orientation':{'start':{'x':0.5,'y':0},'stop':{'x':0.5,'y':1}}}
manifest={
 'fill-specializations':[{'value':gradient('263542','15212B')},
    {'appearance':'dark','value':gradient('293B49','101A24')}],
 'groups':[{'layers':[
  {'name':'雾银盖沿 · Lid','image-name':'Lid.svg','glass':False,'hidden':False},
  {'name':'暖金光核 · Light','image-name':'Light.svg','glass':False,'hidden':False}],
  'shadow':{'kind':'neutral','opacity':0},'specular':False,'translucency':{'enabled':False,'value':0}}],
 'supported-platforms':{'squares':['macOS']}}
(bundle/'icon.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(bundle)
