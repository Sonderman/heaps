package h3d.pass;

enum CubeFaceFlag {
	Right;
	Left;
	Back;
	Front;
	Top;
	Bottom;
}

class PointShadowMap extends Shadows {

	var customDepth : Bool;
	var depth : h3d.mat.DepthBuffer;
	var pshader : h3d.shader.PointShadow;
	var mergePass = new h3d.pass.ScreenFx(new h3d.shader.MinMaxShader.CubeMinMaxShader());
	public var faceMask(default, null) : haxe.EnumFlags<CubeFaceFlag>;

	var cubeDir = [ h3d.Matrix.L([0,0,-1,0, 0,-1,0,0, 1,0,0,0]),
					h3d.Matrix.L([0,0,1,0, 0,-1,0,0, -1,0,0,0]),
	 				h3d.Matrix.L([1,0,0,0, 0,0,1,0, 0,1,0,0]),
	 				h3d.Matrix.L([1,0,0,0, 0,0,-1,0, 0,-1,0,0]),
				 	h3d.Matrix.L([1,0,0,0, 0,-1,0,0, 0,0,1,0]),
				 	h3d.Matrix.L([-1,0,0,0, 0,-1,0,0, 0,0,-1,0]) ];

	public function new( light : h3d.scene.Light, useWorldDist : Bool ) {
		super(light);
		lightCamera = new h3d.Camera();
		lightCamera.screenRatio = 1.0;
		lightCamera.fovY = 90;
		shader = pshader = new h3d.shader.PointShadow();
		customDepth = h3d.Engine.getCurrent().driver.hasFeature(AllocDepthBuffer);
		if( !customDepth ) depth = h3d.mat.DepthBuffer.getDefault();

		faceMask.set(Front);
		faceMask.set(Back);
		faceMask.set(Top);
		faceMask.set(Bottom);
		faceMask.set(Left);
		faceMask.set(Right);
	}

	override function set_mode(m:Shadows.RenderMode) {
		pshader.enable = m != None && enabled;
		return mode = m;
	}

	override function set_enabled(b:Bool) {
		pshader.enable = b && mode != None;
		return enabled = b;
	}

	override function set_size(s) {
		return super.set_size(s);
	}

	override function dispose() {
		super.dispose();
		if( customDepth && depth != null ) depth.dispose();
		if( tmpTex != null) tmpTex.dispose();
	}

	override function isUsingWorldDist(){
		return true;
	}

	override function getShadowTex() {
		return pshader.shadowMap;
	}

	override function setGlobals() {
		super.setGlobals();
		cameraViewProj = getShadowProj();
		cameraFar = lightCamera.zFar;
		cameraPos = lightCamera.pos;
	}

	override function syncShader(texture) {
		var absPos = light.getAbsPos();
		var pointLight = cast(light, h3d.scene.pbr.PointLight);
		pshader.shadowMap = texture;
		pshader.shadowBias = bias;
		pshader.shadowPower = power;
		pshader.lightPos = new h3d.Vector(absPos.tx, absPos.ty, absPos.tz);
		pshader.zFar = pointLight.range;

		// ESM
		pshader.USE_ESM = samplingKind == ESM;
		pshader.shadowPower = power;

		// PCF
		pshader.USE_PCF = samplingKind == PCF;
		pshader.pcfScale = pcfScale / 100.0;
		pshader.pcfQuality = pcfQuality;
	}

	override function saveStaticData() {
		if( mode != Mixed && mode != Static )
			return null;
		if( staticTexture == null )
			throw "Data not computed";

		var buffer = new haxe.io.BytesBuffer();
		buffer.addInt32(staticTexture.width);

		for(i in 0 ... 6){
			var bytes = haxe.zip.Compress.run(staticTexture.capturePixels(i).bytes,9);
			buffer.addInt32(bytes.length);
			buffer.add(bytes);
		}

		return buffer.getBytes();
	}

	override function loadStaticData( bytes : haxe.io.Bytes ) {
		if( (mode != Mixed && mode != Static) || bytes == null || bytes.length == 0 )
			return false;
		var buffer = new haxe.io.BytesInput(bytes);
		var size = buffer.readInt32();
		if( size != this.size )
			return false;

		if( staticTexture != null ) staticTexture.dispose();
		staticTexture = new h3d.mat.Texture(size, size, [Target, Cube], format);
		staticTexture.name = "staticTexture";
		staticTexture.realloc = null;
		staticTexture.preventAutoDispose();

		for(i in 0 ... 6){
			var len = buffer.readInt32();
			var pixels = new hxd.Pixels(size, size, haxe.zip.Uncompress.run(buffer.read(len)), format);
			staticTexture.uploadPixels(pixels, 0, i);
		}
		syncShader(staticTexture);
		return true;
	}

	static var tmpTex : h3d.mat.Texture;
	override function createDefaultShadowMap() {
		if( tmpTex != null) return tmpTex;
		tmpTex = new h3d.mat.Texture(1,1, [Target,Cube], format);
		tmpTex.name = "defaultCubeShadowMap";
		if( format == RGBA )
			tmpTex.clear(0xFFFFFF);
		else
			tmpTex.clearF(1);
		return tmpTex;
	}

	override function draw( passes, ?sort ) {
		if( !enabled )
			return;

		if( !filterPasses(passes) )
			return;

		if( passes.isEmpty() ) {
			syncShader(staticTexture == null ? createDefaultShadowMap() : staticTexture);
			return;
		}

		var pointLight = cast(light, h3d.scene.pbr.PointLight);
		var absPos = light.getAbsPos();
		var sp = new h3d.col.Sphere(absPos.tx, absPos.ty, absPos.tz, pointLight.range);
		cullPasses(passes,function(col) return col.inSphere(sp));

		if( passes.isEmpty() ) {
			syncShader(staticTexture == null ? createDefaultShadowMap() : staticTexture);
			return;
		}

		var texture = ctx.textures.allocTarget("pointShadowMap", size, size, false, format, true);
		if(depth == null || depth.width != size || depth.height != size || depth.isDisposed() ) {
			if( depth != null ) depth.dispose();
			depth = new h3d.mat.DepthBuffer(size, size);
		}
		texture.depthBuffer = depth;

		lightCamera.pos.set(absPos.tx, absPos.ty, absPos.tz);
		lightCamera.zFar = pointLight.range;
		lightCamera.zNear = pointLight.zNear;

		for( i in 0...6 ) {

			// Shadows on the current face is disabled
			if( !faceMask.has(CubeFaceFlag.createByIndex(i)) ) {
				texture.clear(0xFFFFFF, 0, i);
				continue;
			}

			lightCamera.setCubeMap(i);
			lightCamera.update();

			var save = passes.save();
			cullPasses(passes, function(col) return col.inFrustum(lightCamera.frustum));
			if( passes.isEmpty() ) {
				passes.load(save);
				texture.clear(0xFFFFFF, 0, i);
				continue;
			}

			ctx.engine.pushTarget(texture, i);
			ctx.engine.clear(0xFFFFFF, 1);

			super.draw(passes,sort);
			passes.load(save);
			ctx.engine.popTarget();
		}

		// Blur is applied even if there's no shadows - TO DO : remove the useless blur pass
		if( blur.radius > 0 )
			blur.apply(ctx, texture);

		if( mode == Mixed && !ctx.computingStatic )
			syncShader(merge(texture));
		else
			syncShader(texture);
	}

	function merge( dynamicTex : h3d.mat.Texture ) : h3d.mat.Texture{
		var validBakedTexture = (staticTexture != null && staticTexture.width == dynamicTex.width);
		var merge : h3d.mat.Texture = null;
		if( mode == Mixed && !ctx.computingStatic && validBakedTexture)
			merge = ctx.textures.allocTarget("mergedPointShadowMap", size, size, false, format, true);

		if( mode == Mixed && !ctx.computingStatic && merge != null ) {
			for( i in 0 ... 6 ) {
				if( !faceMask.has(CubeFaceFlag.createByIndex(i)) ) continue;
				mergePass.shader.texA = dynamicTex;
				mergePass.shader.texB = staticTexture;
				mergePass.shader.mat = cubeDir[i];
				ctx.engine.pushTarget(merge, i);
				mergePass.render();
				ctx.engine.popTarget();
			}
		}
		return merge;
	}

	override function computeStatic( passes : h3d.pass.PassList ) {
		if( mode != Static && mode != Mixed )
			return;
		draw(passes);
		var texture = pshader.shadowMap;
		var old = staticTexture;
		staticTexture = texture.clone();
		if( old != null ) old.dispose();
		staticTexture.name = "StaticPointShadowMap";
		pshader.shadowMap = staticTexture;
	}
}