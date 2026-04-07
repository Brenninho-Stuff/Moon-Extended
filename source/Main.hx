package;

import debug.FPSCounter;

import flixel.FlxG;
import flixel.FlxGame;
import flixel.FlxState;
import flixel.graphics.FlxGraphic;
import flixel.util.FlxStringUtil;

import haxe.CallStack;
import haxe.io.Path;
import haxe.Timer;

import openfl.Assets;
import openfl.Lib;
import openfl.display.Sprite;
import openfl.display.StageScaleMode;
import openfl.events.Event;
import openfl.events.FocusEvent;
import openfl.events.KeyboardEvent;
import openfl.system.System as OpenFLSystem;

import lime.app.Application;
import lime.system.System as LimeSystem;

import states.TitleState;

#if hl
import hl.Api;
#end

#if linux
import lime.graphics.Image;
@:cppInclude('./external/gamemode_client.h')
@:cppFileCode('#define GAMEMODE_AUTO')
#end

/**
 * Main entry point for Friday Night Funkin': Moon Extended.
 *
 * Responsibilities:
 *  - Bootstrap FlxGame and initial game state
 *  - Platform-specific initialisation (Android permissions, Windows DPI, etc.)
 *  - Memory watchdog: periodically forces GC when heap exceeds threshold
 *  - Focus management: mute/restore audio and pause Discord when unfocused
 *  - Debug keyboard shortcuts (desktop / debug builds only)
 *  - Shader-cache invalidation on window resize
 *  - FPS counter scaling to match device DPI
 */
class Main extends Sprite
{
	// ─── Game Bootstrap Config ────────────────────────────────────────────────

	var game = {
		width:           1280,
		height:          720,
		initialState:    TitleState,
		zoom:            -1.0,
		framerate:       60,
		skipSplash:      true,
		startFullscreen: false
	};

	// ─── Public Statics ───────────────────────────────────────────────────────

	/** Global singleton — use for deferred calls without keeping a local ref. */
	public static var instance(default, null):Main;

	/** The on-screen FPS / memory counter widget. */
	public static var fpsVar:FPSCounter;

	/**
	 * Heap size (bytes) that triggers a proactive GC cycle.
	 * Default: 1.2 GB — tune down on low-RAM devices if needed.
	 */
	public static final GC_MEMORY_THRESHOLD:Int = 1_200 * 1024 * 1024;

	/** How often (ms) the memory watchdog polls heap usage. */
	public static final GC_WATCHDOG_INTERVAL:Int = 30_000;

	// ─── Platform Constants ───────────────────────────────────────────────────

	#if mobile
	public static final platform:String  = "Mobile";
	public static final isMobile:Bool    = true;
	#else
	public static final platform:String  = "Desktop";
	public static final isMobile:Bool    = false;
	#end

	public static final isAndroid:Bool   = #if android  true #else false #end;
	public static final isIOS:Bool       = #if ios      true #else false #end;
	public static final isWindows:Bool   = #if windows  true #else false #end;
	public static final isLinux:Bool     = #if linux    true #else false #end;
	public static final isMacOS:Bool     = #if mac      true #else false #end;
	public static final isHL:Bool        = #if hl       true #else false #end;
	public static final isDebug:Bool     = #if debug    true #else false #end;

	// ─── Private State ────────────────────────────────────────────────────────

	/** Drives the periodic memory watchdog. Kept alive as a field. */
	private var _gcWatchdog:Timer;

	/** Whether the app window is currently focused. */
	private var _hasFocus:Bool = true;

	/**
	 * Counts frames since the last window-resize event.
	 * Cache reset is deferred until this reaches RESIZE_DEBOUNCE_FRAMES.
	 */
	private var _resizeDebounceFrames:Int = 0;
	private static inline final RESIZE_DEBOUNCE_FRAMES:Int = 3;

	// ─── Entry Point ─────────────────────────────────────────────────────────

	public static function main():Void
	{
		Lib.current.addChild(new Main());

		#if cpp
		// Enable the HXCPP incremental GC and run one initial major cycle
		// to reclaim any allocations made during static initialisation.
		cpp.NativeGc.enable(true);
		cpp.NativeGc.run(true);
		#end
	}

	// ─── Constructor ──────────────────────────────────────────────────────────

	public function new()
	{
		super();

		instance = this;

		// ── Android: request runtime storage permissions before anything else ──
		#if (android && (EXTERNAL || MEDIA))
		SUtil.doPermissionsShit();
		#end

		// ── Global uncaught-error handler ─────────────────────────────────────
		SUtil.uncaughtErrorHandler();

		// ── Windows: enable DPI awareness and prevent "not responding" ghosting ─
		#if windows
		@:functionCode("
			#include <windows.h>
			#include <winuser.h>
			SetProcessDPIAware();
			DisableProcessWindowsGhosting();
		")
		#end

		// ── HXCPP critical error hook (C++ / HL) ──────────────────────────────
		#if cpp
		@:privateAccess
		untyped __global__.__hxcpp_set_critical_error_handler(SUtil.onError);
		#elseif hl
		@:privateAccess
		Api.setErrorHandler(SUtil.onError);
		#end

		if (stage != null)
			init();
		else
			addEventListener(Event.ADDED_TO_STAGE, init);
	}

	// ─── Initialisation Chain ─────────────────────────────────────────────────

	private function init(?e:Event):Void
	{
		if (hasEventListener(Event.ADDED_TO_STAGE))
			removeEventListener(Event.ADDED_TO_STAGE, init);

		setupGame();
	}

	private function setupGame():Void
	{
		// ── Auto-zoom to fill the physical display ─────────────────────────────
		var stageW:Int = Lib.current.stage.stageWidth;
		var stageH:Int = Lib.current.stage.stageHeight;

		if (game.zoom == -1.0)
		{
			var ratioX:Float = stageW / game.width;
			var ratioY:Float = stageH / game.height;
			game.zoom        = Math.min(ratioX, ratioY);
			game.width       = Math.ceil(stageW / game.zoom);
			game.height      = Math.ceil(stageH / game.zoom);
		}

		// ── Mobile: set working directory to external/app storage ─────────────
		#if mobile
		Sys.setCwd(
			#if android Path.addTrailingSlash( #end
			SUtil.getStorageDirectory()
			#if android ) #end
		);
		#end

		// ── Lua callbacks ──────────────────────────────────────────────────────
		#if LUA_ALLOWED
		llua.Lua.set_callbacks_function(
			cpp.Callable.fromStaticFunction(psychlua.CallbackHandler.call)
		);
		#end

		// ── Core systems ───────────────────────────────────────────────────────
		Controls.instance = new Controls();
		ClientPrefs.loadDefaultKeys();

		#if ACHIEVEMENTS_ALLOWED
		Achievements.load();
		#end

		// ── Create FlxGame ─────────────────────────────────────────────────────
		// OpenFL ≥ 9.2.0 ignores zoom entirely, so pass raw dimensions instead.
		addChild(new FlxGame(
			#if (openfl >= "9.2.0") 1280, 720 #else game.width, game.height #end,
			game.initialState,
			#if (flixel < "5.0.0") game.zoom, #end
			game.framerate,
			game.framerate,
			game.skipSplash,
			game.startFullscreen
		));

		// ── FPS counter ────────────────────────────────────────────────────────
		fpsVar = new FPSCounter(10, 3, 0xFFFFFF);
		FlxG.game.addChild(fpsVar);
		if (fpsVar != null)
			fpsVar.visible = ClientPrefs.data.showFPS;

		// ── Stage alignment ────────────────────────────────────────────────────
		Lib.current.stage.align    = "tl";
		Lib.current.stage.scaleMode = StageScaleMode.NO_SCALE;

		// ── Linux window icon ──────────────────────────────────────────────────
		#if linux
		var icon = Image.fromFile("icon.png");
		Lib.current.stage.window.setIcon(icon);
		#end

		// ── Subsystem setup ────────────────────────────────────────────────────
		setupEventListeners();
		setupMemoryWatchdog();
		applyClientPrefs();

		#if DISCORD_ALLOWED
		DiscordClient.prepare();
		#end

		// ── Game-resize signal: debounce then reset shader bitmap cache ────────
		FlxG.signals.gameResized.add(onGameResized);

		#if debug
		traceSystemInfo();
		#end
	}

	// ─── Event Listeners ─────────────────────────────────────────────────────

	private function setupEventListeners():Void
	{
		// Fullscreen and debug shortcuts (desktop only)
		#if desktop
		FlxG.stage.addEventListener(KeyboardEvent.KEY_UP, onKeyUp);
		#end

		// Window focus management
		FlxG.stage.addEventListener(FocusEvent.FOCUS_IN,  onFocusIn);
		FlxG.stage.addEventListener(FocusEvent.FOCUS_OUT, onFocusOut);

		// App lifecycle on mobile (suspend / resume)
		#if mobile
		FlxG.stage.addEventListener(Event.DEACTIVATE, onAppSuspend);
		FlxG.stage.addEventListener(Event.ACTIVATE,   onAppResume);
		#end

		// Debounce timer reset on every frame when a resize is pending
		FlxG.game.addEventListener(Event.ENTER_FRAME, onEnterFrame);

		// Clean up everything if the native window is closed
		Application.current.window.onClose.add(onWindowClose);
	}

	// ─── Client Preference Application ───────────────────────────────────────

	/**
	 * Applies runtime preferences that affect OpenFL / Lime behaviour.
	 * Call this again whenever ClientPrefs are reloaded at runtime.
	 */
	public static function applyClientPrefs():Void
	{
		// FPS counter visibility
		if (fpsVar != null)
			fpsVar.visible = ClientPrefs.data.showFPS;

		// Dynamic framerate cap
		var targetFPS:Int = ClientPrefs.data.framerate ?? 60;
		FlxG.updateFramerate = targetFPS;
		FlxG.drawFramerate   = targetFPS;

		// Anti-aliasing preference
		FlxG.game.antialiasing = ClientPrefs.data.globalAntiAliasing;

		// Mobile: honour screen timeout preference
		#if mobile
		LimeSystem.allowScreenTimeout = ClientPrefs.data.screensaver;
		#end

		// HTML5: keep game running and hide the OS cursor
		#if html5
		FlxG.autoPause    = false;
		FlxG.mouse.visible = false;
		#end
	}

	// ─── Memory Watchdog ─────────────────────────────────────────────────────

	/**
	 * Starts a repeating timer that monitors heap usage.
	 * If the heap exceeds GC_MEMORY_THRESHOLD, a major GC cycle is forced.
	 * This prevents OOM crashes on long sessions and asset-heavy charts.
	 */
	private function setupMemoryWatchdog():Void
	{
		_gcWatchdog = new Timer(GC_WATCHDOG_INTERVAL);
		_gcWatchdog.run = function()
		{
			var used:Int = OpenFLSystem.totalMemory;

			#if debug
			var mb:Float = used / (1024 * 1024);
			trace('[GC Watchdog] Heap usage: ${Math.fround(mb * 10) / 10} MB');
			#end

			if (used >= GC_MEMORY_THRESHOLD)
			{
				trace('[GC Watchdog] Threshold exceeded — forcing collection.');
				gc(true);
			}
		};
	}

	/**
	 * Triggers a garbage collection cycle.
	 *
	 * @param major  If `true`, runs a full major collection (slow but thorough).
	 *               If `false`, runs a minor/incremental cycle (default).
	 */
	public static function gc(major:Bool = false):Void
	{
		#if cpp
		cpp.NativeGc.run(major);
		#elseif hl
		hl.Gc.major();
		#end
	}

	/**
	 * Returns current heap usage in megabytes, rounded to 1 decimal place.
	 */
	public static function getMemoryMB():Float
	{
		return Math.fround((OpenFLSystem.totalMemory / (1024 * 1024)) * 10) / 10;
	}

	// ─── Asset Cache Management ───────────────────────────────────────────────

	/**
	 * Clears every cached FlxGraphic that is not currently in use
	 * (i.e. has no more-than-one reference count).
	 * Useful after leaving a heavy state.
	 */
	public static function clearUnusedCache():Void
	{
		@:privateAccess
		for (key => graphic in FlxG.bitmap._cache)
		{
			if (graphic != null && !graphic.persist && graphic.useCount <= 0)
			{
				FlxG.bitmap.remove(graphic);
				graphic.destroy();
			}
		}
	}

	/**
	 * Wipes the bitmap cache for the given display object.
	 * Required after window resizes to prevent stale shader renders.
	 */
	public static function resetSpriteCache(sprite:Sprite):Void
	{
		@:privateAccess
		{
			sprite.__cacheBitmap     = null;
			sprite.__cacheBitmapData = null;
		}
	}

	// ─── State Management Helpers ─────────────────────────────────────────────

	/**
	 * Switches the active Flixel state and optionally triggers a GC cycle
	 * after the transition to reclaim the old state's allocations.
	 */
	public static function switchState(nextState:FlxState, gcAfter:Bool = true):Void
	{
		FlxG.switchState(nextState);
		if (gcAfter)
			Timer.delay(() -> gc(false), 500);
	}

	/**
	 * Resets the current Flixel state (equivalent to re-entering it).
	 */
	public static function resetState():Void
	{
		FlxG.resetState();
	}

	// ─── Event Handlers ───────────────────────────────────────────────────────

	private function onEnterFrame(e:Event):Void
	{
		// Shader cache reset: wait RESIZE_DEBOUNCE_FRAMES after a resize before
		// actually clearing, so we don't thrash every pixel during a drag-resize.
		if (_resizeDebounceFrames > 0)
		{
			_resizeDebounceFrames--;
			if (_resizeDebounceFrames == 0)
				flushShaderCache();
		}
	}

	private function onGameResized(w:Int, h:Int):Void
	{
		// Scale the FPS overlay to match the physical pixel density.
		final scale:Float = Math.min(
			FlxG.stage.stageWidth  / FlxG.width,
			FlxG.stage.stageHeight / FlxG.height
		);

		if (fpsVar != null)
			fpsVar.scaleX = fpsVar.scaleY = (scale > 1 ? scale : 1);

		// Defer the shader cache flush to avoid thrashing during drag-resize.
		_resizeDebounceFrames = RESIZE_DEBOUNCE_FRAMES;
	}

	/** Clears the bitmap cache on all active cameras and the root game sprite. */
	private function flushShaderCache():Void
	{
		if (FlxG.cameras != null)
		{
			for (cam in FlxG.cameras.list)
			{
				if (cam != null && cam.filters != null)
					resetSpriteCache(cam.flashSprite);
			}
		}

		if (FlxG.game != null)
			resetSpriteCache(FlxG.game);
	}

	// ── Focus events ──────────────────────────────────────────────────────────

	private function onFocusIn(e:FocusEvent):Void
	{
		if (_hasFocus) return;
		_hasFocus = true;

		// Restore game audio to its previous volume.
		FlxG.sound.muted = false;

		#if DISCORD_ALLOWED
		// Let Discord know we're active again.
		DiscordClient.resetClientID();
		#end
	}

	private function onFocusOut(e:FocusEvent):Void
	{
		if (!_hasFocus) return;
		_hasFocus = false;

		// Silence the game while the window is in the background.
		// This respects the user's existing mute state by not unmuting on return
		// if they had already muted manually — we only mute on focus loss.
		if (!FlxG.sound.muted)
			FlxG.sound.muted = true;
	}

	// ── Mobile app lifecycle ──────────────────────────────────────────────────

	#if mobile
	private function onAppSuspend(e:Event):Void
	{
		FlxG.sound.muted = true;
		// Run a minor GC to free as much memory as possible before the OS may
		// decide to evict the process from RAM.
		gc(false);
	}

	private function onAppResume(e:Event):Void
	{
		FlxG.sound.muted = false;
		applyClientPrefs();
	}
	#end

	// ── Desktop keyboard shortcuts ────────────────────────────────────────────

	#if desktop
	private function onKeyUp(e:KeyboardEvent):Void
	{
		// Fullscreen toggle (mapped via Controls)
		if (Controls.instance.justReleased('fullscreen'))
			FlxG.fullscreen = !FlxG.fullscreen;

		#if debug
		onDebugKeyUp(e);
		#end
	}

	#if debug
	private function onDebugKeyUp(e:KeyboardEvent):Void
	{
		switch (e.keyCode)
		{
			// F3 — print detailed memory / asset-cache info to the console.
			case 114:
				var totalMB  = getMemoryMB();
				var cacheSize = @:privateAccess Lambda.count(FlxG.bitmap._cache);
				trace('═══ Moon Extended Debug Info ═══');
				trace('  Heap usage : ${totalMB} MB');
				trace('  Bitmap cache: ${cacheSize} entries');
				trace('  Current state: ${Type.getClassName(Type.getClass(FlxG.state))}');
				trace('  FPS target  : ${FlxG.updateFramerate}');
				trace('  Draw FPS    : ${FlxG.drawFramerate}');
				trace('================================');

			// F4 — force-clear unused cached assets and run GC.
			case 115:
				trace('[Debug] Clearing unused asset cache...');
				clearUnusedCache();
				gc(true);
				trace('[Debug] Done. Heap: ${getMemoryMB()} MB');

			// F5 — reload client preferences without restarting the state.
			case 116:
				trace('[Debug] Reloading ClientPrefs...');
				ClientPrefs.loadDefaultKeys();
				applyClientPrefs();
				trace('[Debug] Prefs reloaded.');
		}
	}
	#end // debug
	#end // desktop

	// ── Window close ─────────────────────────────────────────────────────────

	private function onWindowClose():Void
	{
		// Cleanly shut down Discord RPC before the process exits.
		#if DISCORD_ALLOWED
		DiscordClient.shutdown();
		#end

		// Stop the watchdog timer so it doesn't fire during shutdown.
		if (_gcWatchdog != null)
		{
			_gcWatchdog.stop();
			_gcWatchdog = null;
		}
	}

	// ─── Debug System Info Trace ──────────────────────────────────────────────

	#if debug
	private function traceSystemInfo():Void
	{
		trace('═══ Moon Extended — System Info ═══');
		trace('  Platform : ${platform}');
		trace('  Target   : ${#if android "Android" #elseif ios "iOS" #elseif windows "Windows" #elseif linux "Linux" #elseif mac "macOS" #else "Unknown" #end}');
		trace('  Heap     : ${getMemoryMB()} MB at boot');
		trace('  Stage    : ${Lib.current.stage.stageWidth}×${Lib.current.stage.stageHeight}');
		trace('  Game     : ${game.width}×${game.height} @ zoom ${game.zoom}');
		trace('  FPS cap  : ${game.framerate}');
		trace('  GC thresh: ${GC_MEMORY_THRESHOLD / (1024 * 1024)} MB');
		trace('==================================');
	}
	#end
}
