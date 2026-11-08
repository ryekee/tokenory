"""Model and render the Tokenory mechanical counter in Blender, with camera and two editable passes."""
import bpy, math, sys
from pathlib import Path
from mathutils import Vector
from math import pi, sin, cos
from mathutils.geometry import tessellate_polygon
out = Path(__file__).resolve().parent
proof = '--proof' in sys.argv
bpy.ops.wm.read_factory_settings(use_empty=True)
scene=bpy.context.scene
scene.render.engine='CYCLES'
scene.cycles.samples=12 if proof else 48
scene.cycles.use_denoising=True
scene.cycles.transparent_max_bounces=4
scene.render.film_transparent=True
scene.render.image_settings.file_format='PNG'
scene.render.image_settings.color_mode='RGBA'
scene.render.resolution_x=scene.render.resolution_y=1024
scene.render.resolution_percentage=42 if proof else 100
scene.view_settings.view_transform='Khronos PBR Neutral'
scene.render.threads_mode='FIXED'
scene.render.threads=10
scene.render.use_persistent_data=True
world=bpy.data.worlds.new('Studio ambient');scene.world=world;world.use_nodes=True
world.node_tree.nodes['Background'].inputs[0].default_value=(.62,.72,.87,1)
world.node_tree.nodes['Background'].inputs[1].default_value=.32
def rgb(s):
    n=[int(s[i:i+2],16)/255 for i in (0,2,4)]
    return tuple(v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in n)
def material(name,color,metal=0,rough=.37,coat=0):
    m=bpy.data.materials.new(name);m.diffuse_color=(*rgb(color),1);m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF')
    for k,v in [('Base Color',m.diffuse_color),('Metallic',metal),('Roughness',rough),('Coat Weight',coat),('Coat Roughness',.24)]:
        p.inputs[k].default_value=v
    return m
enamel=material('Chart orange | enamel','EA792D',.29,.26,.32)
lip=material('Orange lip | softbox-facing finish','FF9F55',.34,.24,.35)
inner=material('Burnt orange recessed wall','A64D0A',.22,.38)
base=material('Ink blue | mechanism bed','102033',.24,.41)
drum=material('Parchment | porcelain drums','E7E5D9',.11,.31,.17)
unit=material('Ivory | units drum','F4E7CD',.12,.32,.12)
ink=material('Midnight | fixed print','182636',.04,.38)
units_ink=material('Chart token blue | printed units','2E579E',.08,.36)
index_ink=material('Chart token blue | enamel index','2E579E',.33,.28)
shell_objects=[];mechanism=[]
def object_mesh(name,vertices,faces,materials,group,indices=None):
    mesh=bpy.data.meshes.new(name);mesh.from_pydata(vertices,[],faces);mesh.update()
    o=bpy.data.objects.new(name,mesh);scene.collection.objects.link(o)
    for m in materials:mesh.materials.append(m)
    if indices:
        for poly,index in zip(mesh.polygons,indices):poly.material_index=index
    group.append(o);return o
def radiused_loop(w,h,r,segments=24):
    coords=[]
    for cx,cy,a0 in [(w/2-r,h/2-r,0),(-w/2+r,h/2-r,90),(-w/2+r,-h/2+r,180),(w/2-r,-h/2+r,270)]:
        for i in range(segments+1):
            angle=math.radians(a0+90*i/segments)
            coords.append((cx+r*cos(angle),cy+r*sin(angle)))
    return coords
# Profiles define the entire moulded exterior, its continuous rim, and the deep well.
profiles=[(4.25,4.20,.60,-.53),(4.34,4.29,.63,-.49),(4.39,4.34,.64,-.425),
          (4.55,4.51,.69,1.29),(4.54,4.50,.685,1.34),(4.50,4.46,.67,1.378),
          (4.44,4.40,.65,1.392),(4.04,3.97,.49,1.392),(3.992,3.922,.472,1.373),
          (3.963,3.893,.457,1.327),(3.908,3.838,.429,.94),(3.887,3.817,.419,.86),(3.877,3.807,.415,-.28)]
def shell_height(x,y,z):
    # Slight thumb relief at the middle of the front rail, with smooth shoulders.
    if y >= -1.70 or abs(x)>=.90: return z
    strength = 1 if abs(x)<.57 else (1+cos(pi*(abs(x)-.57)/.33))/2
    return z-.53*strength*max(0,(z-.45))/.94
# Add matching subdivisions across each long straight span for the front thumb relief.
verts=[];rows=[]
for w,h,r,z in profiles:
    ring=radiused_loop(w,h,r);row=[]
    for n,(x,y) in enumerate(ring):
        X,Y=ring[(n+1)%len(ring)]
        divisions=56 if abs(X-x)>1 and abs(Y-y)<.0001 else 1
        for j in range(divisions):
            xx=x+(X-x)*j/divisions; yy=y+(Y-y)*j/divisions
            row.append(len(verts));verts.append((xx,yy,shell_height(xx,yy,z)))
    rows.append(row)
faces=[];inds=[]
for row_idx,(a,b) in enumerate(zip(rows,rows[1:])):
    for j in range(len(a)):
        k=(j+1)%len(a);faces.append((a[j],a[k],b[k],b[j]))
        inds.append(1 if row_idx in (4,5,6,7) else (2 if row_idx>=8 else 0))
shell=object_mesh('01 | Enamel housing',verts,faces,[enamel,lip,inner],shell_objects,inds)
for p in shell.data.polygons:p.use_smooth=True
# A rounded internal bed is sized to stay within the casing even at the front corners.
def slab(name,w,h,r,z,m,group):
    xy=radiused_loop(w,h,r);verts=[(x,y,z) for x,y in xy];return object_mesh(name,verts,[tuple(range(len(xy)))],[m],group)
bed=slab('02 | Spindle bed',4.02,3.95,.50,-.27,base,mechanism)
cy,cz,R=-.07,-.98,2.25
centers=(-1.24,0,1.24)
def roller(name,xc,w,mat):
    # Arc length spans the functional window, leaving a slim dark gap between wheels.
    sizes=[(-w/2,-.025),(-w/2+.025,0),(w/2-.025,0),(w/2,-.025)]
    v=[];rows=[]
    for xx,offset in sizes:
        row=[]
        for i in range(121):
            th=math.radians(-54+108*i/120);rr=R+offset
            row.append(len(v));v.append((xc+xx,cy+rr*sin(th),cz+rr*cos(th)))
        rows.append(row)
    f=[]
    for a,b in zip(rows,rows[1:]):
        for j in range(120):f.append((a[j],b[j],b[j+1],a[j+1]))
    o=object_mesh(name,v,f,[mat],mechanism)
    for p in o.data.polygons:p.use_smooth=True
for idx,x in enumerate(centers): roller('03 | '+['Hundreds','Tens','Units'][idx]+' drum',x,1.205,unit if idx==2 else drum)

# Convert optical-size-independent numerals to meshes and conform each vertex to its drum.
font=bpy.data.fonts.load('/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf')
def print_num(number,x,theta,height,mat):
    curve=bpy.data.curves.new('DIN '+str(number),'FONT');curve.body=str(number);curve.font=font;curve.resolution_u=20
    text=bpy.data.objects.new('Print '+str(number),curve);scene.collection.objects.link(text)
    bpy.context.view_layer.objects.active=text;text.select_set(True)
    bpy.ops.object.convert(target='MESH');text=bpy.context.object
    import bmesh
    bm=bmesh.new();bm.from_mesh(text.data)
    bmesh.ops.triangulate(bm,faces=list(bm.faces))
    bmesh.ops.subdivide_edges(bm,edges=list(bm.edges),cuts=7,use_grid_fill=True)
    bm.to_mesh(text.data);bm.free()
    pts=[v.co.copy() for v in text.data.vertices]
    xmin=min(v.x for v in pts);xmax=max(v.x for v in pts);ymin=min(v.y for v in pts);ymax=max(v.y for v in pts)
    factor=height/(ymax-ymin)
    for v,p in zip(text.data.vertices,pts):
        xx=(p.x-(xmin+xmax)/2)*factor;yy=(p.y-(ymin+ymax)/2)*factor
        angle=math.radians(theta)+yy/R;rr=R+.009
        v.co=(x+xx,cy+rr*sin(angle),cz+rr*cos(angle))
    text.data.materials.append(mat);text.name=f'04 | Printed {number}';mechanism.append(text)
    for p in text.data.polygons:p.use_smooth=True
    text.select_set(False)
print_num(6,centers[0],-4,1.56,ink);print_num(4,centers[1],-4,1.56,ink)
print_num(8,centers[2],16,1.48,units_ink);print_num(9,centers[2],-30,1.48,units_ink)
# The exposed adjustment wheel sits inside the lowered front rail.
wheel_mat=material('Reset control | machined graphite','233044',.65,.31)
vs=[];fs=[];segments=180
for xx,ring_radius in [(-.525,.115),(-.49,.15),(.49,.15),(.525,.115)]:
    for j in range(segments):
        t=2*pi*j/segments
        radius=ring_radius-(.015 if j%4 in (0,1) else 0)
        vs.append((xx,-2.095+radius*sin(t),.984+radius*cos(t)))
for row in range(3):
    for j in range(segments):
        k=(j+1)%segments;a=row*segments;b=a+segments
        fs.append((a+j,b+j,b+k,a+k))
fs.extend([tuple(reversed(range(segments))),tuple(range(3*segments,4*segments))])
object_mesh('05 | Knurled adjustment barrel',vs,fs,[wheel_mat],shell_objects)
# Geometric pointer marks the reading line on the centre of the right rail.
object_mesh('05 | Blue index',[(2.00,-.04,1.395),(2.13,-.115,1.395),(2.13,.035,1.395)],[(0,1,2)],[index_ink],shell_objects)
def light(name,pos,power,size,color,target=(0,0,.7)):
    dat=bpy.data.lights.new(name,'AREA');dat.energy=power;dat.shape='DISK';dat.size=size;dat.color=color
    o=bpy.data.objects.new(name,dat);scene.collection.objects.link(o);o.location=pos
    o.rotation_euler=(Vector(target)-o.location).to_track_quat('-Z','Y').to_euler()
light('Large west softbox',(-5,-3,9),960,6.5,(1,.94,.86))
light('Window strip',(4.8,3,6.5),710,5,(.76,.87,1))
light('Front fill',(1,-6,4),155,4,(.83,.91,1))
cam=bpy.data.cameras.new('Things reference elevation');co=bpy.data.objects.new('Camera',cam);scene.collection.objects.link(co)
target=Vector((0,0,.46));angle=math.radians(51.5);distance=27
co.location=target+Vector((0,-distance*cos(angle),distance*sin(angle)))
co.rotation_euler=(target-co.location).to_track_quat('-Z','Y').to_euler()
cam.lens=177;cam.sensor_width=36;scene.camera=co
def render(name):
    scene.render.filepath=str(out/name);bpy.ops.render.render(write_still=True)
if '--shell-only' in sys.argv:
    for o in mechanism:o.is_holdout=True
    render('shell-pass.png')
elif proof:
    render('proof.png')
else:
    scene.render.filepath='//beauty.png'
    bpy.context.preferences.filepaths.save_version=0
    bpy.ops.wm.save_as_mainfile(filepath=str(out/'Tokenory Counter.blend'),compress=True)
    render('beauty.png')
    for o in shell_objects:o.visible_camera=False
    render('register-pass.png')
    for o in shell_objects:o.visible_camera=True
    for o in mechanism:o.is_holdout=True
    render('shell-pass.png')
