import { inflateSync } from 'node:zlib';

// The luminance grid the visual-content gate measures: one averaged luminance
// sample per 8x8 pixel block, row-major, each value in 0..1. Block resolution is
// enough to tell a rendered scene from a flat screen and costs nothing extra for
// a JPEG, whose 8x8 blocks are the transform units already parsed below.
export const LUMA_BLOCK = 8;

const LUMA_COLS = width => Math.ceil(width / LUMA_BLOCK);
const LUMA_ROWS = height => Math.ceil(height / LUMA_BLOCK);

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
}

/**
 * Unfilters a PNG's inflated scanlines and reduces them to the block luminance
 * grid. Only the row filters the decoder above already accepted (0..4) are
 * handled; anything else was rejected before this runs.
 */
function pngLuma(raw, width, height, channels) {
  const cols = LUMA_COLS(width), rows = LUMA_ROWS(height);
  const values = new Float64Array(cols * rows);
  const detail = new Float64Array(cols * rows);
  const stride = width * channels + 1;
  const luma = new Float64Array(width * height);
  let prev = Buffer.alloc(width * channels);
  let cur = Buffer.alloc(width * channels);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * stride];
    const row = raw.subarray(y * stride + 1, y * stride + 1 + width * channels);
    for (let i = 0; i < cur.length; i++) {
      const a = i >= channels ? cur[i - channels] : 0;
      const b = prev[i];
      const c = i >= channels ? prev[i - channels] : 0;
      let predictor = 0;
      if (filter === 1) predictor = a;
      else if (filter === 2) predictor = b;
      else if (filter === 3) predictor = Math.floor((a + b) / 2);
      else if (filter === 4) predictor = paeth(a, b, c);
      cur[i] = (row[i] + predictor) & 0xff;
    }
    for (let x = 0; x < width; x++) {
      const o = x * channels;
      luma[y * width + x] = channels === 1 ? cur[o] : 0.299 * cur[o] + 0.587 * cur[o + 1] + 0.114 * cur[o + 2];
    }
    const swap = prev; prev = cur; cur = swap;
  }
  // Block average (0..1) and block detail. Detail is the count of pixels
  // deviating from the block's own mean, scaled to 0..63 - the same scale the
  // JPEG path produces from its AC coefficients - so a flat block is 0 and a
  // block crossed by an edge is large.
  for (let by = 0; by < rows; by++) {
    const y0 = by * LUMA_BLOCK, y1 = Math.min(y0 + LUMA_BLOCK, height);
    for (let bx = 0; bx < cols; bx++) {
      const x0 = bx * LUMA_BLOCK, x1 = Math.min(x0 + LUMA_BLOCK, width);
      const index = by * cols + bx;
      let sum = 0, count = 0;
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { sum += luma[y * width + x]; count += 1; }
      const mean = count ? sum / count : 0;
      values[index] = mean / 255;
      let deviating = 0;
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) if (Math.abs(luma[y * width + x] - mean) > 6) deviating += 1;
      detail[index] = deviating * 63 / 64;
    }
  }
  return { cols, rows, values, detail };
}

// Decode the complete stream, not just dimensions. Native JPEG decoders may
// repair truncated input, so count every baseline entropy block ourselves.
// With `{ luma: true }` the same walk also reconstructs each 8x8 luminance
// block's average (its DC term) and its detail (its nonzero AC coefficients), so
// the visual-content gate reuses this parser instead of adding a second decoder.
export function decodeRaster(input, options = {}) {
  const wantLuma = options.luma === true;
  const b=Buffer.from(input);
  const need=(ok,message)=>{if(!ok)throw new Error(message);};
  if(b.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) {
    let p=8,width,height,channels,ended=false,dataEnded=false;const parts=[];
    while(p<b.length) {
      need(p+12<=b.length,'PNG_TRUNCATED');const n=b.readUInt32BE(p),kind=b.toString('ascii',p+4,p+8);
      need(p+n+12<=b.length,'PNG_TRUNCATED');let crc=0xffffffff;
      for(let i=p+4;i<p+8+n;i++){crc^=b[i];for(let k=0;k<8;k++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}
      need(((crc^0xffffffff)>>>0)===b.readUInt32BE(p+8+n),'PNG_CRC');need(width || kind==='IHDR','PNG_HEADER');
      if(kind==='IHDR') {
        need(p===8 && n===13,'PNG_HEADER');width=b.readUInt32BE(p+8);height=b.readUInt32BE(p+12);
        need(width>0 && height>0 && width*height<=16777216,'PNG_SIZE');
        need(b[p+16]===8 && [2,6].includes(b[p+17]) && b[p+18]===0 && b[p+19]===0 && b[p+20]===0,'PNG_MODE');channels=b[p+17]===2?3:4;
      } else if(kind==='IDAT'){need(!dataEnded,'PNG_DATA_ORDER');parts.push(b.subarray(p+8,p+8+n));}
      else if(kind==='IEND'){need(n===0 && parts.length>0 && p+12===b.length,'PNG_END');ended=true;}
      else {need(kind==='PLTE' || (b[p+4]&32)!==0,'PNG_CRITICAL_CHUNK');if(parts.length)dataEnded=true;}
      p+=n+12;
    }
    need(ended,'PNG_END');const stride=width*channels+1;
    const raw=inflateSync(Buffer.concat(parts),{maxOutputLength:height*stride});
    need(raw.length===height*stride,'PNG_SCANLINES');for(let y=0;y<height;y++)need(raw[y*stride]<=4,'PNG_FILTER');
    return wantLuma?{format:'png',width,height,luma:pngLuma(raw,width,height,channels)}:{format:'png',width,height};
  }
  need(b.length>=4 && b[0]===255 && b[1]===216,'IMAGE_FORMAT_UNSUPPORTED');
  let p=2,width,height,components,scan=false;const tables=new Map(),quant=new Map();let lumaGrid=null;
  while(p<b.length) {
    need(b[p++]===255,'JPEG_MARKER');while(b[p]===255)p++;const marker=b[p++];
    if(marker===217){need(scan && p===b.length,'JPEG_END');return wantLuma?{format:'jpeg',width,height,luma:lumaGrid}:{format:'jpeg',width,height};}
    need(!scan,'JPEG_TRAILING_SEGMENT');
    need(p+2<=b.length,'JPEG_TRUNCATED');const length=b.readUInt16BE(p),end=p+length;p+=2;
    need(length>=2 && end<=b.length,'JPEG_TRUNCATED');
    if(marker===192) {
      need(!components && b[p]===8,'JPEG_FRAME');height=b.readUInt16BE(p+1);width=b.readUInt16BE(p+3);const count=b[p+5];
      need(width>0 && height>0 && width*height<=16777216 && [1,3].includes(count) && end-p===6+3*count,'JPEG_SIZE');components=[];
      for(let i=0;i<count;i++){const q=p+6+i*3,h=b[q+1]>>4,v=b[q+1]&15;need(h>0&&h<=4&&v>0&&v<=4&&!components.some(c=>c.id===b[q]),'JPEG_SAMPLING');components.push({id:b[q],h,v,q:b[q+2]});}
    } else if(marker===219) {
      while(p<end){const id=b[p++];need(id<=3 && p+64<=end,'JPEG_QUANTIZATION');const table=new Uint16Array(64);for(let i=0;i<64;i++){need(b[p+i]>0,'JPEG_QUANTIZATION');table[i]=b[p+i];}quant.set(id,table);p+=64;}
    } else if(marker===196) {
      while(p<end){const id=b[p++];need((id<=3 || (id>=16&&id<=19)) && p+16<=end,'JPEG_HUFFMAN');const counts=Array.from(b.subarray(p,p+16));p+=16;const table=new Map();let code=0;
        for(let bits=1;bits<=16;bits++){need(code+counts[bits-1]<(1<<bits),'JPEG_HUFFMAN');for(let i=0;i<counts[bits-1];i++){need(p<end,'JPEG_HUFFMAN');table.set(`${bits}:${code++}`,b[p++]);}code*=2;}tables.set(id,table);
      }
    } else if(marker===218) {
      need(components && !scan && b[p]===components.length && end-p===1+2*components.length+3,'JPEG_SCAN');const ordered=[];
      for(let i=0;i<components.length;i++){const q=p+1+2*i,c=components.find(c=>c.id===b[q]);need(c&&!ordered.includes(c)&&quant.has(c.q),'JPEG_COMPONENT');c.dc=tables.get(b[q+1]>>4);c.ac=tables.get(16+(b[q+1]&15));c.qtable=quant.get(c.q);c.pred=0;need(c.dc&&c.ac,'JPEG_TABLE');ordered.push(c);}
      need(b[end-3]===0&&b[end-2]===63&&b[end-1]===0,'JPEG_SCAN_MODE');p=end;
      let bits=0,value=0;
      const bit=()=>{if(bits===0){need(p<b.length,'JPEG_ENTROPY_TRUNCATED');value=b[p++];if(value===255)need(b[p++]===0,'JPEG_ENTROPY_TRUNCATED');bits=8;}return (value>>--bits)&1;};
      const readBits=n=>{let v=0;for(let i=0;i<n;i++)v=v*2+bit();return v;};
      const symbol=table=>{let code=0;for(let n=1;n<=16;n++){code=code*2+bit();const s=table.get(`${n}:${code}`);if(s!==undefined)return s;}throw new Error('JPEG_ENTROPY_CODE');};
      const skip=n=>{for(let i=0;i<n;i++)bit();};
      const maxH=components.length===1?1:Math.max(...components.map(c=>c.h)),maxV=components.length===1?1:Math.max(...components.map(c=>c.v));
      const columns=Math.ceil(width/(8*maxH)),rows=Math.ceil(height/(8*maxV));
      // The luminance component's own block grid: one 8x8 block per sample, at
      // the Y plane's full resolution (a 4:2:0 image has two Y blocks per axis in
      // each MCU). Its DC term is the block's average (DC/8 + 128 after
      // dequantization) and its nonzero AC coefficients are the detail inside the
      // block - which is exactly what tells a rendered scene from a smooth field,
      // with no IDCT required.
      const yc=ordered[0];
      if(wantLuma)lumaGrid={cols:Math.ceil(width/8),rows:Math.ceil(height/8),values:new Float64Array(Math.ceil(width/8)*Math.ceil(height/8)),detail:new Float64Array(Math.ceil(width/8)*Math.ceil(height/8))};
      for(let m=0;m<columns*rows;m++)for(const c of ordered)for(let block=0;block<(components.length===1?1:c.h*c.v);block++){
        const size=symbol(c.dc);need(size<=11,'JPEG_DC');
        let diff=0;
        if(size>0){const raw=readBits(size);diff=raw>=(1<<(size-1))?raw:raw-((1<<size)-1);}
        c.pred+=diff;
        const isY=wantLuma && c===yc;
        const mcuCol=m%columns,mcuRow=Math.floor(m/columns);
        const col=mcuCol*c.h+block%c.h,row=mcuRow*c.v+Math.floor(block/c.h);
        const inGrid=isY && col<lumaGrid.cols && row<lumaGrid.rows;
        if(inGrid){
          const average=c.pred*(c.qtable[0]||1)/8+128;
          lumaGrid.values[row*lumaGrid.cols+col]=Math.min(255,Math.max(0,average))/255;
        }
        let k=1,nonzero=0;
        while(k<64){const ac=symbol(c.ac),run=ac>>4,size2=ac&15;if(ac===0)break;if(size2===0){need(run===15,'JPEG_AC');k+=16;need(k<=64,'JPEG_AC');}else{k+=run;need(k<64&&size2<=10,'JPEG_AC');skip(size2);nonzero+=1;k++;}}
        if(inGrid)lumaGrid.detail[row*lumaGrid.cols+col]=nonzero;
      }
      while(bits>0)need(bit()===1,'JPEG_PADDING');scan=true;continue;
    } else {need((marker>=224&&marker<=239)||marker===254,'JPEG_MODE_UNSUPPORTED');}
    p=end;
  }
  throw new Error('JPEG_END');
}

export function decodeRasterLuma(input) {
  return decodeRaster(input, { luma: true });
}

// Sample on both sides of capture without installing persistent resources.
export async function captureGeometry(client,execute) {
  return execute(client.studioId,'Client',`local gui=game:GetService('GuiService')
local svc=game:GetService('StudioDeviceSimulatorService');local id=svc:GetDeviceAsync();assert(id~='default','configured device required')
local info=svc:GetDeviceInfoAsync(id);local resolution=svc:GetResolutionAsync();local orientation=svc:GetOrientationAsync().Name
local full=gui:GetInsetArea(Enum.ScreenInsets.None);local safe=gui:GetInsetArea(Enum.ScreenInsets.DeviceSafeInsets);local viewport=workspace.CurrentCamera.ViewportSize
local function rect(r)return {x=r.Min.X-full.Min.X,y=r.Min.Y-full.Min.Y,width=r.Width,height=r.Height}end
assert(viewport.X==safe.Width and viewport.Y==safe.Height,'camera safe-area origin unproven')
local portrait=info.DeviceForm.Name=='Phone' and orientation=='Portrait'
local device={id=id,surface=if info.DeviceForm.Name=='Phone' then 'mobile' else 'desktop',width=if portrait then resolution.Y else resolution.X,height=if portrait then resolution.X else resolution.Y,orientation=orientation,form=info.DeviceForm.Name,scaling=svc:GetScalingModeAsync().Name}
local controls={};local playerGui=game:GetService('Players').LocalPlayer.PlayerGui
for _,item in playerGui:GetDescendants() do
 if item:IsA('GuiObject') and (item:IsA('GuiButton') or item:IsA('TextLabel') or item:IsA('TextBox')) then
  local visible=item.Visible;local ancestor=item.Parent;local nested=false;local screenName=''
  -- A clipping ancestor (a scrolled sheet) is what the player actually sees through: the part of a
  -- control outside it is not drawn, so the measured rectangle is the intersection, and a control
  -- scrolled fully out of it is not on screen at all.
  local clipMinX,clipMinY,clipMaxX,clipMaxY=-math.huge,-math.huge,math.huge,math.huge
  while ancestor and ancestor~=playerGui do
   if ancestor:IsA('GuiObject') then visible=visible and ancestor.Visible;if ancestor:IsA('GuiButton') then nested=true end
    if ancestor.ClipsDescendants then local ap,as=ancestor.AbsolutePosition,ancestor.AbsoluteSize;clipMinX,clipMinY=math.max(clipMinX,ap.X),math.max(clipMinY,ap.Y);clipMaxX,clipMaxY=math.min(clipMaxX,ap.X+as.X),math.min(clipMaxY,ap.Y+as.Y) end end
   if ancestor:IsA('ScreenGui') then visible=visible and ancestor.Enabled;screenName=ancestor.Name end
   ancestor=ancestor.Parent
  end
  local robloxCore=screenName=='Chat' or screenName=='BubbleChat' or screenName=='TouchGui' or screenName=='Freecam' or screenName=='RobloxGui' or screenName=='ProximityPrompts' or screenName=='PlayerList' or screenName=='Health' or screenName=='Backpack' or screenName=='MainMenu' or screenName=='ErrorPrompt'
  if visible and not nested and not robloxCore and (not item:IsA('TextLabel') or item.Text~='') then
   assert(item.AbsoluteRotation==0,'rotated critical UI unsupported')
   local rawPos=item.AbsolutePosition;local rawSize=item.AbsoluteSize
   local minX,minY=math.max(rawPos.X,clipMinX),math.max(rawPos.Y,clipMinY)
   local maxX,maxY=math.min(rawPos.X+rawSize.X,clipMaxX),math.min(rawPos.Y+rawSize.Y,clipMaxY)
   local pos=Vector2.new(minX,minY);local size=Vector2.new(math.max(0,maxX-minX),math.max(0,maxY-minY))
   if size.X>0 and size.Y>0 then
    -- The live text-scale fact: a label that scales to its control must carry its own
    -- UITextSizeConstraint cap. Source text cannot establish that for an instantiated label, so
    -- it is measured here and validated below.
    local scaled=item.TextScaled==true
    local cap=nil
    if scaled then local constraint=item:FindFirstChildOfClass('UITextSizeConstraint');if constraint then cap=constraint.MaxTextSize end end
    table.insert(controls,{id=item:GetFullName(),x=pos.X-full.Min.X,y=pos.Y-full.Min.Y,width=size.X,height=size.Y,scaled=scaled,cap=cap})
   end
  end
 end
end
table.sort(controls,function(a,b)return a.id<b.id end)
-- The Roblox chat window owns the top-left corner. It is core UI, so it is not in
-- the owned critical-UI set; it is measured on its own and validateGeometry fails
-- any capture whose owned UI is laid over it. Only frame chrome is measured, and
-- never a container that fills the screen, so the rectangle is the chat window
-- rather than the whole ScreenGui and stays stable across the two samples.
local chat=nil
local chatGui=playerGui:FindFirstChild('Chat')
if chatGui and chatGui:IsA('ScreenGui') and chatGui.Enabled then
 local minX,minY,maxX,maxY
 local maxWidth,maxHeight=viewport.X*0.6,viewport.Y*0.75
 for _,item in chatGui:GetDescendants() do
  if item:IsA('Frame') and item.Visible then
   local pos,size=item.AbsolutePosition,item.AbsoluteSize
   local named=item.Name=='ChatWindow' or item.Name=='ChatChannelParentFrame' or item.Name=='ChatBarParentFrame' or item.Name=='ChatBar'
   local sized=size.X>=80 and size.Y>=16 and size.X<=maxWidth and size.Y<=maxHeight
   if named or sized then
    minX=math.min(minX or pos.X,pos.X);minY=math.min(minY or pos.Y,pos.Y)
    maxX=math.max(maxX or pos.X+size.X,pos.X+size.X);maxY=math.max(maxY or pos.Y+size.Y,pos.Y+size.Y)
   end
  end
 end
 if minX then chat={x=minX-full.Min.X,y=minY-full.Min.Y,width=maxX-minX,height=maxY-minY} end
end
local value={device=device,chat=chat,logical={full={x=0,y=0,width=full.Width,height=full.Height},viewport={x=safe.Min.X-full.Min.X,y=safe.Min.Y-full.Min.Y,width=viewport.X,height=viewport.Y},safeArea=rect(safe),insets={left=safe.Min.X-full.Min.X,top=safe.Min.Y-full.Min.Y,right=full.Max.X-safe.Max.X,bottom=full.Max.Y-safe.Max.Y}},criticalUI=controls}`);
}

export function validateGeometry(g, expected) {
  const finite=x=>typeof x==='number'&&Number.isFinite(x);
  const rect=r=>r&&finite(r.x)&&finite(r.y)&&finite(r.width)&&finite(r.height)&&r.width>0&&r.height>0;
  const inside=(a,b)=>a.x>=b.x&&a.y>=b.y&&a.x+a.width<=b.x+b.width&&a.y+a.height<=b.y+b.height;
  const d=g?.device,l=g?.logical;
  if(!d || !expected || d.id!==expected.id || d.width!==expected.width || d.height!==expected.height || d.surface!==expected.surface || d.scaling!=='ActualResolution' || (d.surface==='mobile' && (d.orientation!=='Portrait'||d.form!=='Phone')) || (d.surface==='desktop'&&d.form!=='Desktop'))throw new Error('DEVICE_CONFIG_MISMATCH');
  if(!l || !rect(l.full)||!rect(l.viewport)||!rect(l.safeArea)||l.full.x!==0||l.full.y!==0||!inside(l.viewport,l.full)||!inside(l.safeArea,l.full))throw new Error('CAPTURE_LOGICAL_GEOMETRY');
  const i=l.insets,s=l.safeArea;if(!i||i.left!==s.x||i.top!==s.y||i.right!==l.full.width-s.x-s.width||i.bottom!==l.full.height-s.y-s.height)throw new Error('CAPTURE_INSETS');
  if(!Array.isArray(g.criticalUI)||!g.criticalUI.length||g.criticalUI.length>4096)throw new Error('CRITICAL_UI_MISSING');const ids=new Set();
  for(const [n,r]of g.criticalUI.entries()){
    if(!rect(r)||typeof r.id!=='string'||!r.id||ids.has(r.id)||!inside(r,l.safeArea))throw new Error('CRITICAL_UI_BOUNDS '+JSON.stringify({element:r,safeArea:l.safeArea,invalidRect:!rect(r),duplicate:typeof r.id==='string'&&ids.has(r.id)}));ids.add(r.id);
    // A scaled label grows its glyphs to fill the control it lives in; without its own constraint cap
    // it renders at the control's own height. A sample that reports the fact is held to it; an older
    // sample without the field is judged on the rectangles it does have.
    if(r.scaled===true && !(typeof r.cap==='number' && Number.isFinite(r.cap) && r.cap>0 && r.cap<=32))throw new Error('CRITICAL_UI_TEXT_SCALE_UNCAPPED '+JSON.stringify({element:{id:r.id,cap:r.cap??null}}));
    for(const o of g.criticalUI.slice(0,n))if(r.x<o.x+o.width&&o.x<r.x+r.width&&r.y<o.y+o.height&&o.y<r.y+r.height)throw new Error('CRITICAL_UI_OVERLAP '+JSON.stringify({element:r,other:o}));
  }
  // The chat frame is a reserved region, not owned UI: nothing this run owns may
  // sit on it. A capture taken before this check existed simply carries no chat
  // rectangle and is judged on the rectangles it does have.
  const chat=g.chat;
  if(chat!==undefined&&chat!==null){
    if(!rect(chat)||!inside(chat,l.safeArea))throw new Error('CAPTURE_CHAT_GEOMETRY '+JSON.stringify({chat,safeArea:l.safeArea}));
    for(const r of g.criticalUI)if(r.x<chat.x+chat.width&&chat.x<r.x+r.width&&r.y<chat.y+chat.height&&chat.y<r.y+r.height)throw new Error('CRITICAL_UI_CHAT_OVERLAP '+JSON.stringify({element:r,chat}));
  }
}

if(import.meta.main && process.argv[2]==='--raster') {
  try {const input=JSON.parse(await Bun.stdin.text());const bytes=Buffer.from(input.hex,'hex');process.stdout.write(JSON.stringify(decodeRaster(bytes)));}
  catch(error){process.stderr.write(String(error.message));process.exitCode=1;}
}

export async function deviceStep(step,client,execute) {
  const measured=await execute(client.studioId,'Client',`local svc=game:GetService('StudioDeviceSimulatorService')
local p=game:GetService('Players').LocalPlayer
local http=game:GetService('HttpService')
local gui=game:GetService('GuiService')
local diagnostic=p:FindFirstChild('ForgeQADeviceDiagnostic')
assert(not diagnostic,'device diagnostic already exists')
diagnostic=Instance.new('Folder');diagnostic.Name='ForgeQADeviceDiagnostic';diagnostic.Parent=p
local function persist(key,data)
 local entry=diagnostic:FindFirstChild(key) or Instance.new('StringValue');entry.Name=key;entry.Value=http:JSONEncode(data);entry.Parent=diagnostic
end
local function sample()
 local camera=workspace.CurrentCamera
 local id=svc:GetDeviceAsync();local value={id=id,orientation=svc:GetOrientationAsync().Name,viewport={width=camera.ViewportSize.X,height=camera.ViewportSize.Y}}
 if id~='default' then local info=svc:GetDeviceInfoAsync(id);value.form=info.DeviceForm.Name;local size=svc:GetResolutionAsync();value.width=size.X;value.height=size.Y;value.dpi=svc:GetPixelDensityAsync();value.scaling=svc:GetScalingModeAsync().Name end
 return value
end
local function geometry()
 local full=gui:GetInsetArea(Enum.ScreenInsets.None);local safe=gui:GetInsetArea(Enum.ScreenInsets.DeviceSafeInsets)
 local a,b=gui:GetGuiInset();local v=workspace.CurrentCamera.ViewportSize
 return {viewport={width=v.X,height=v.Y},full={width=full.Width,height=full.Height},safe={width=safe.Width,height=safe.Height},guiInset={topLeft={a.X,a.Y},bottomRight={b.X,b.Y}}}
end
local before=sample()
persist('before',before)
local desired={form=${JSON.stringify(step.surface==='mobile'?'Phone':'Desktop')},orientation=${step.surface==='mobile'?JSON.stringify(step.height>step.width?'Portrait':'LandscapeLeft'):'nil'},width=${step.width},height=${step.height},scaling='ActualResolution'}
persist('desired',desired)
local old=p:FindFirstChild('ForgeQADeviceRestore')
if not old then
 old=Instance.new('StringValue');old.Name='ForgeQADeviceRestore';old.Parent=p
 old.Value=http:JSONEncode(before)
end
local selected
for _,id in svc:GetDeviceListAsync() do local info=svc:GetDeviceInfoAsync(id);if info.DeviceForm==Enum.DeviceForm.${step.surface==='mobile'?'Phone':'Desktop'} and info.Width==${Math.max(step.width,step.height)} and info.Height==${Math.min(step.width,step.height)} then selected=id;break end end
assert(selected,'required device form unavailable')
local selectedInfo=svc:GetDeviceInfoAsync(selected)
persist('selected',{id=selected,form=selectedInfo.DeviceForm.Name,width=selectedInfo.Width,height=selectedInfo.Height,dpi=selectedInfo.PixelDensity,resolutionScale=selectedInfo.ResolutionScale})
local ready=false;local thread;local done=false;local configured=false
local function check()
 if not configured or not workspace.CurrentCamera then return end
 local g=geometry();local v=g.viewport
 ready=v.width>0 and v.height>0 and v.width==g.safe.width and v.height==g.safe.height and g.safe.width<=g.full.width and g.safe.height<=g.full.height and ${step.height>step.width?'v.height>v.width':'v.width>v.height'}
 if ready and thread and not done then done=true;task.spawn(thread) end
end
-- ViewportSize is updated during PreRender. Observe that engine event after
-- setters, not an assumed pixel size or an unconditional configuration event.
local c=game:GetService('RunService').PreRender:Connect(check)
local timeout
local ok,err=pcall(function()
 svc:SetDeviceAsync(selected)
 ${step.surface==='mobile'?`svc:SetOrientationAsync(Enum.ScreenOrientation.${step.height>step.width?'Portrait':'LandscapeLeft'})`:''}
 svc:SetResolutionAsync(${Math.max(step.width,step.height)},${Math.min(step.width,step.height)})
 svc:SetScalingModeAsync(Enum.DeviceSimulatorScalingMode.ActualResolution)
 configured=true;thread=coroutine.running();timeout=task.delay(${step.timeout_seconds},function() if not done then done=true;task.spawn(thread) end end);coroutine.yield()
 assert(ready,'viewport predicate timeout')
end);c:Disconnect();if timeout and coroutine.status(timeout)=='suspended' then task.cancel(timeout) end
local actual=sample()
persist('actual',actual)
local area=geometry();persist('geometry',area)
local screenGuis={};for _,item in p.PlayerGui:GetChildren() do if item:IsA('ScreenGui') then table.insert(screenGuis,{name=item.Name,ignoreGuiInset=item.IgnoreGuiInset,screenInsets=item.ScreenInsets.Name,size={item.AbsoluteSize.X,item.AbsoluteSize.Y}}) end end;persist('screenGuis',screenGuis)
local matched=actual.id==selected and actual.form==desired.form and actual.width==math.max(desired.width,desired.height) and actual.height==math.min(desired.width,desired.height) and actual.scaling==desired.scaling and (not desired.orientation or actual.orientation==desired.orientation)
local evidence={before=before,desired=desired,actual=actual,selected=selected}
persist('failure',{ok=ok and matched,error=if not ok then tostring(err) elseif not matched then 'device state mismatch' else nil})
assert(ok and matched,'DEVICE_SETUP_FAILED: ForgeQADeviceDiagnostic retained')
local portrait=actual.orientation=='Portrait' and actual.form=='Phone'
local value={device=selected,width=if portrait then actual.height else actual.width,height=if portrait then actual.width else actual.height,orientation=actual.orientation,viewport=actual.viewport,geometry=area,evidence=evidence}`);
  if(measured.width!==step.width || measured.height!==step.height) throw new Error('DEVICE_CONFIG_MISMATCH '+JSON.stringify({desired:{width:step.width,height:step.height},actual:measured}));
  if(step.surface==='mobile' && measured.orientation!=='Portrait')throw new Error('DEVICE_ORIENTATION_MISMATCH');
  return measured;
}
// Retrieve bounded sections before restoration; engine error strings are truncated.
export async function collectDeviceDiagnostics(client,execute) {
  const result={};
  for(const section of ['before','desired','selected','actual','geometry','screenGuis','failure']) {
    const value=await execute(client.studioId,'Client',`local folder=game:GetService('Players').LocalPlayer:FindFirstChild('ForgeQADeviceDiagnostic')
local entry=folder and folder:FindFirstChild('${section}');local value={present=entry~=nil}
if entry then value.data=game:GetService('HttpService'):JSONDecode(entry.Value) end`);
    if(value.present)result[section]=value.data;
  }
  return result;
}
export const restoreDeviceCode=`local p=game:GetService('Players').LocalPlayer;local marker=p:FindFirstChild('ForgeQADeviceRestore')
if marker then local saved=game:GetService('HttpService'):JSONDecode(marker.Value);local svc=game:GetService('StudioDeviceSimulatorService')
if saved.id=='default' then svc:StopSimulationAsync() else
 svc:SetDeviceAsync(saved.id)
 local form=svc:GetDeviceInfoAsync(saved.id).DeviceForm
 if form==Enum.DeviceForm.Phone or form==Enum.DeviceForm.Tablet then svc:SetOrientationAsync(Enum.ScreenOrientation[saved.orientation]) end
 svc:SetResolutionAsync(saved.width,saved.height);svc:SetPixelDensityAsync(saved.dpi);svc:SetScalingModeAsync(Enum.DeviceSimulatorScalingMode[saved.scaling])
end
marker:Destroy() end
local diagnostic=p:FindFirstChild('ForgeQADeviceDiagnostic');if diagnostic then diagnostic:Destroy() end`;

export async function motionStep(step,client,execute) {
  const path=JSON.stringify(step.target);
  return execute(client.studioId,'Client',`local p=game:GetService('Players').LocalPlayer;local name='ForgeQAMotion';local folder=p:FindFirstChild(name)
${step.op==='motion_begin'?`assert(not folder,'motion trace already active');folder=Instance.new('Folder');folder.Name=name;folder.Parent=p
local target=game;for segment in string.gmatch(${path},'[^.]+') do target=target:FindFirstChild(segment);assert(target,'motion target missing') end
local root=target:FindFirstChild('HumanoidRootPart');assert(root,'motion root missing')
local count=0;local started=os.clock();local nextSample=0;local c
c=game:GetService('RunService').PostSimulation:Connect(function()
 local elapsed=os.clock()-started;if elapsed<nextSample or count>=600 then return end;nextSample=elapsed+0.05;count+=1
 local joints={};for _,joint in root:GetChildren() do if joint:IsA('Motor6D') then joints[joint.Name]={joint.C0:GetComponents()} end end
 local value=Instance.new('StringValue');value.Name=tostring(count);value.Value=game:GetService('HttpService'):JSONEncode({elapsedSeconds=elapsed,mode=target:GetAttribute('ForgeWildlifeState'),feedback=target:GetAttribute('ForgeWildlifeFeedback'),healthMilli=target:GetAttribute('ForgeWildlifeHealthMilli'),position={root.Position.X,root.Position.Y,root.Position.Z},velocity={root.AssemblyLinearVelocity.X,root.AssemblyLinearVelocity.Y,root.AssemblyLinearVelocity.Z},joints=joints});value.Parent=folder
end);folder.Destroying:Once(function() c:Disconnect() end)
local value={recording=true,maximumSamples=600,maximumHz=20}`:`assert(folder,'motion trace absent');local samples=folder:GetChildren();table.sort(samples,function(a,b)return tonumber(a.Name)<tonumber(b.Name) end)
local http=game:GetService('HttpService');local values={};for i=math.max(1,#samples-5),#samples do local sample=samples[i];table.insert(values,http:JSONDecode(sample.Value)) end
while #values>2 and #http:JSONEncode({samples=values,video=false})>8000 do table.remove(values,1) end
folder:Destroy();assert(#values>1,'motion trace missing frames');local value={samples=values,video=false}`}`);
}

export async function obstacleStep(step,client,serverId,execute) {
  if(step.remove) return execute(serverId,'Server',`local wall=workspace:FindFirstChild('ForgeQAObstacle');assert(wall,'owned obstacle absent');wall:Destroy();local value={removed=true}`);
  return execute(serverId,'Server',`assert(not workspace:FindFirstChild('ForgeQAObstacle'),'owned obstacle exists')
local actor=game:GetService('Players'):GetPlayerByUserId(${Number(client.userId)});local from=actor and actor.Character and actor.Character:FindFirstChild('HumanoidRootPart');assert(from,'actor root missing')
local target=game;for segment in string.gmatch(${JSON.stringify(step.target)},'[^.]+') do target=target:FindFirstChild(segment);assert(target,'obstacle target missing') end
local root=if target:IsA('Model') then target:FindFirstChild('HumanoidRootPart') else target;assert(root and root:IsA('BasePart'),'target root missing')
local delta=root.Position-from.Position;assert(delta.Magnitude>1 and delta.Magnitude<=8,'obstacle case must already be inside attack reach')
local wall=Instance.new('Part');wall.Name='ForgeQAObstacle';wall.Anchored=true;wall.Size=Vector3.new(10,12,0.5);wall.CFrame=CFrame.lookAt((from.Position+root.Position)/2,root.Position);wall.Parent=workspace
local value={created=true,distance=delta.Magnitude}`);
}

export async function turnCamera(client,execute,call) {
  try {
    await execute(client.studioId,'Client',`local p=game:GetService('Players').LocalPlayer;assert(not p:FindFirstChild('ForgeQACameraTurn'),'camera observer exists')
local m=Instance.new('BoolValue');m.Name='ForgeQACameraTurn';m.Parent=p;local camera=workspace.CurrentCamera;local before=camera.CFrame.LookVector
local input=false;local a=game:GetService('UserInputService').InputBegan:Connect(function(i,processed) if i.KeyCode==Enum.KeyCode.RightBracket and not processed then input=true end end)
local b=camera:GetPropertyChangedSignal('CFrame'):Connect(function() if input and before:Dot(camera.CFrame.LookVector)<0.99 then m.Value=true end end)
m.Destroying:Once(function() a:Disconnect();b:Disconnect() end);local value={subscribed=true}`);
    await call('user_keyboard_input',{studio_id:client.studioId,datamodel_type:'Client',actions:[{action:'keyPress',key_code:'RightBracket'}]});
    return await execute(client.studioId,'Client',`local m=game:GetService('Players').LocalPlayer.ForgeQACameraTurn
if not m.Value then observe(m.Changed,function() return true end,function() return not m.Value end) end
assert(m.Value,'camera angle did not change');local value={turned=true}`);
  } finally {await execute(client.studioId,'Client',`local m=game:GetService('Players').LocalPlayer:FindFirstChild('ForgeQACameraTurn');if m then m:Destroy() end;local value={clean=true}`);}
}
