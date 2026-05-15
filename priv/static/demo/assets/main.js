//#region \0vite/modulepreload-polyfill.js
(function polyfill() {
	const relList = document.createElement("link").relList;
	if (relList && relList.supports && relList.supports("modulepreload")) return;
	for (const link of document.querySelectorAll("link[rel=\"modulepreload\"]")) processPreload(link);
	new MutationObserver((mutations) => {
		for (const mutation of mutations) {
			if (mutation.type !== "childList") continue;
			for (const node of mutation.addedNodes) if (node.tagName === "LINK" && node.rel === "modulepreload") processPreload(node);
		}
	}).observe(document, {
		childList: true,
		subtree: true
	});
	function getFetchOpts(link) {
		const fetchOpts = {};
		if (link.integrity) fetchOpts.integrity = link.integrity;
		if (link.referrerPolicy) fetchOpts.referrerPolicy = link.referrerPolicy;
		if (link.crossOrigin === "use-credentials") fetchOpts.credentials = "include";
		else if (link.crossOrigin === "anonymous") fetchOpts.credentials = "omit";
		else fetchOpts.credentials = "same-origin";
		return fetchOpts;
	}
	function processPreload(link) {
		if (link.ep) return;
		link.ep = true;
		const fetchOpts = getFetchOpts(link);
		fetch(link.href, fetchOpts);
	}
})();
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/disclose-version.js
if (typeof window !== "undefined") ((window.__svelte ??= {}).v ??= /* @__PURE__ */ new Set()).add("5");
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/flags/index.js
/** True if experimental.async=true */
var async_mode_flag = false;
/** True if we're not certain that we only have Svelte 5 code in the compilation */
var legacy_mode_flag = false;
function enable_legacy_mode_flag() {
	legacy_mode_flag = true;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/flags/legacy.js
enable_legacy_mode_flag();
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/constants.js
var HYDRATION_ERROR = {};
var UNINITIALIZED = Symbol();
var NAMESPACE_HTML = "http://www.w3.org/1999/xhtml";
var ATTACHMENT_KEY = "@attach";
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/shared/utils.js
var is_array = Array.isArray;
var index_of = Array.prototype.indexOf;
var includes = Array.prototype.includes;
var array_from = Array.from;
var define_property = Object.defineProperty;
var get_descriptor = Object.getOwnPropertyDescriptor;
var get_descriptors = Object.getOwnPropertyDescriptors;
var object_prototype = Object.prototype;
var array_prototype = Array.prototype;
var get_prototype_of = Object.getPrototypeOf;
var is_extensible = Object.isExtensible;
/**
* @param {any} thing
* @returns {thing is Function}
*/
function is_function(thing) {
	return typeof thing === "function";
}
var noop$1 = () => {};
/** @param {Function} fn */
function run(fn) {
	return fn();
}
/** @param {Array<() => void>} arr */
function run_all(arr) {
	for (var i = 0; i < arr.length; i++) arr[i]();
}
/**
* TODO replace with Promise.withResolvers once supported widely enough
* @template [T=void]
*/
function deferred() {
	/** @type {(value: T) => void} */
	var resolve;
	/** @type {(reason: any) => void} */
	var reject;
	return {
		promise: new Promise((res, rej) => {
			resolve = res;
			reject = rej;
		}),
		resolve,
		reject
	};
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/constants.js
/**
* An effect that does not destroy its child effects when it reruns.
* Runs as part of render effects, i.e. not eagerly as part of tree traversal or effect flushing.
*/
var MANAGED_EFFECT = 1 << 24;
var CLEAN = 1024;
var DIRTY = 2048;
var MAYBE_DIRTY = 4096;
var INERT = 8192;
var DESTROYED = 16384;
/** Set once a reaction has run for the first time */
var REACTION_RAN = 32768;
/** Effect is in the process of getting destroyed. Can be observed in child teardown functions */
var DESTROYING = 1 << 25;
/**
* 'Transparent' effects do not create a transition boundary.
* This is on a block effect 99% of the time but may also be on a branch effect if its parent block effect was pruned
*/
var EFFECT_TRANSPARENT = 65536;
var EFFECT_PRESERVED = 1 << 19;
var USER_EFFECT = 1 << 20;
/**
* Tells that we marked this derived and its reactions as visited during the "mark as (maybe) dirty"-phase.
* Will be lifted during execution of the derived and during checking its dirty state (both are necessary
* because a derived might be checked but not executed). This is a pure performance optimization flag and
* should not be used for any other purpose!
*/
var WAS_MARKED = 65536;
var REACTION_IS_UPDATING = 1 << 21;
var ASYNC = 1 << 22;
var ERROR_VALUE = 1 << 23;
var STATE_SYMBOL = Symbol("$state");
var LEGACY_PROPS = Symbol("legacy props");
var LOADING_ATTR_SYMBOL = Symbol("");
var ATTRIBUTES_CACHE = Symbol("attributes");
var CLASS_CACHE = Symbol("class");
var STYLE_CACHE = Symbol("style");
var TEXT_CACHE = Symbol("text");
var FORM_RESET_HANDLER = Symbol("form reset");
/** allow users to ignore aborted signal errors if `reason.name === 'StaleReactionError` */
var STALE_REACTION = new class StaleReactionError extends Error {
	name = "StaleReactionError";
	message = "The reaction that called `getAbortSignal()` was re-run or destroyed";
}();
var IS_XHTML = !!globalThis.document?.contentType && /* @__PURE__ */ globalThis.document.contentType.includes("xml");
/**
* `%name%(...)` can only be used during component initialisation
* @param {string} name
* @returns {never}
*/
function lifecycle_outside_component(name) {
	throw new Error(`https://svelte.dev/e/lifecycle_outside_component`);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/errors.js
/**
* Cannot create a `$derived(...)` with an `await` expression outside of an effect tree
* @returns {never}
*/
function async_derived_orphan() {
	throw new Error(`https://svelte.dev/e/async_derived_orphan`);
}
/**
* `%rune%` cannot be used inside an effect cleanup function
* @param {string} rune
* @returns {never}
*/
function effect_in_teardown(rune) {
	throw new Error(`https://svelte.dev/e/effect_in_teardown`);
}
/**
* Effect cannot be created inside a `$derived` value that was not itself created inside an effect
* @returns {never}
*/
function effect_in_unowned_derived() {
	throw new Error(`https://svelte.dev/e/effect_in_unowned_derived`);
}
/**
* `%rune%` can only be used inside an effect (e.g. during component initialisation)
* @param {string} rune
* @returns {never}
*/
function effect_orphan(rune) {
	throw new Error(`https://svelte.dev/e/effect_orphan`);
}
/**
* Maximum update depth exceeded. This typically indicates that an effect reads and writes the same piece of state
* @returns {never}
*/
function effect_update_depth_exceeded() {
	throw new Error(`https://svelte.dev/e/effect_update_depth_exceeded`);
}
/**
* Cannot do `bind:%key%={undefined}` when `%key%` has a fallback value
* @param {string} key
* @returns {never}
*/
function props_invalid_value(key) {
	throw new Error(`https://svelte.dev/e/props_invalid_value`);
}
/**
* `setContext` must be called when a component first initializes, not in a subsequent effect or after an `await` expression
* @returns {never}
*/
function set_context_after_init() {
	throw new Error(`https://svelte.dev/e/set_context_after_init`);
}
/**
* Property descriptors defined on `$state` objects must contain `value` and always be `enumerable`, `configurable` and `writable`.
* @returns {never}
*/
function state_descriptors_fixed() {
	throw new Error(`https://svelte.dev/e/state_descriptors_fixed`);
}
/**
* Cannot set prototype of `$state` object
* @returns {never}
*/
function state_prototype_fixed() {
	throw new Error(`https://svelte.dev/e/state_prototype_fixed`);
}
/**
* Updating state inside `$derived(...)`, `$inspect(...)` or a template expression is forbidden. If the value should not be reactive, declare it without `$state`
* @returns {never}
*/
function state_unsafe_mutation() {
	throw new Error(`https://svelte.dev/e/state_unsafe_mutation`);
}
/**
* A `<svelte:boundary>` `reset` function cannot be called while an error is still being handled
* @returns {never}
*/
function svelte_boundary_reset_onerror() {
	throw new Error(`https://svelte.dev/e/svelte_boundary_reset_onerror`);
}
/**
* Reading a derived belonging to a now-destroyed effect may result in stale values
*/
function derived_inert() {
	console.warn(`https://svelte.dev/e/derived_inert`);
}
/**
* Hydration failed because the initial UI does not match what was rendered on the server. The error occurred near %location%
* @param {string | undefined | null} [location]
*/
function hydration_mismatch(location) {
	console.warn(`https://svelte.dev/e/hydration_mismatch`);
}
/**
* The `value` property of a `<select multiple>` element should be an array, but it received a non-array value. The selection will be kept as is.
*/
function select_multiple_invalid_value() {
	console.warn(`https://svelte.dev/e/select_multiple_invalid_value`);
}
/**
* A `<svelte:boundary>` `reset` function only resets the boundary the first time it is called
*/
function svelte_boundary_reset_noop() {
	console.warn(`https://svelte.dev/e/svelte_boundary_reset_noop`);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/hydration.js
/** @import { TemplateNode } from '#client' */
/**
* Use this variable to guard everything related to hydration code so it can be treeshaken out
* if the user doesn't use the `hydrate` method and these code paths are therefore not needed.
*/
var hydrating = false;
/** @param {boolean} value */
function set_hydrating(value) {
	hydrating = value;
}
/**
* The node that is currently being hydrated. This starts out as the first node inside the opening
* <!--[--> comment, and updates each time a component calls `$.child(...)` or `$.sibling(...)`.
* When entering a block (e.g. `{#if ...}`), `hydrate_node` is the block opening comment; by the
* time we leave the block it is the closing comment, which serves as the block's anchor.
* @type {TemplateNode}
*/
var hydrate_node;
/** @param {TemplateNode | null} node */
function set_hydrate_node(node) {
	if (node === null) {
		hydration_mismatch();
		throw HYDRATION_ERROR;
	}
	return hydrate_node = node;
}
function hydrate_next() {
	return set_hydrate_node(/* @__PURE__ */ get_next_sibling(hydrate_node));
}
/** @param {TemplateNode} node */
function reset(node) {
	if (!hydrating) return;
	if (/* @__PURE__ */ get_next_sibling(hydrate_node) !== null) {
		hydration_mismatch();
		throw HYDRATION_ERROR;
	}
	hydrate_node = node;
}
function next(count = 1) {
	if (hydrating) {
		var i = count;
		var node = hydrate_node;
		while (i--) node = /* @__PURE__ */ get_next_sibling(node);
		hydrate_node = node;
	}
}
/**
* Skips or removes (depending on {@link remove}) all nodes starting at `hydrate_node` up until the next hydration end comment
* @param {boolean} remove
*/
function skip_nodes(remove = true) {
	var depth = 0;
	var node = hydrate_node;
	while (true) {
		if (node.nodeType === 8) {
			var data = node.data;
			if (data === "]") {
				if (depth === 0) return node;
				depth -= 1;
			} else if (data === "[" || data === "[!" || data[0] === "[" && !isNaN(Number(data.slice(1)))) depth += 1;
		}
		var next = /* @__PURE__ */ get_next_sibling(node);
		if (remove) node.remove();
		node = next;
	}
}
/**
*
* @param {TemplateNode} node
*/
function read_hydration_instruction(node) {
	if (!node || node.nodeType !== 8) {
		hydration_mismatch();
		throw HYDRATION_ERROR;
	}
	return node.data;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/equality.js
/** @import { Equals } from '#client' */
/** @type {Equals} */
function equals(value) {
	return value === this.v;
}
/**
* @param {unknown} a
* @param {unknown} b
* @returns {boolean}
*/
function safe_not_equal(a, b) {
	return a != a ? b == b : a !== b || a !== null && typeof a === "object" || typeof a === "function";
}
/** @type {Equals} */
function safe_equals(value) {
	return !safe_not_equal(value, this.v);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/context.js
/** @import { ComponentContext, DevStackEntry, Effect } from '#client' */
/** @type {ComponentContext | null} */
var component_context = null;
/** @param {ComponentContext | null} context */
function set_component_context(context) {
	component_context = context;
}
/**
* Retrieves the context that belongs to the closest parent component with the specified `key`.
* Must be called during component initialisation.
*
* [`createContext`](https://svelte.dev/docs/svelte/svelte#createContext) is a type-safe alternative.
*
* @template T
* @param {any} key
* @returns {T}
*/
function getContext(key) {
	return get_or_init_context_map("getContext").get(key);
}
/**
* Associates an arbitrary `context` object with the current component and the specified `key`
* and returns that object. The context is then available to children of the component
* (including slotted content) with `getContext`.
*
* Like lifecycle functions, this must be called during component initialisation.
*
* [`createContext`](https://svelte.dev/docs/svelte/svelte#createContext) is a type-safe alternative.
*
* @template T
* @param {any} key
* @param {T} context
* @returns {T}
*/
function setContext(key, context) {
	const context_map = get_or_init_context_map("setContext");
	if (async_mode_flag) {
		var flags = active_effect.f;
		if (!(!active_reaction && (flags & 32) !== 0 && !component_context.i)) set_context_after_init();
	}
	context_map.set(key, context);
	return context;
}
/**
* Checks whether a given `key` has been set in the context of a parent component.
* Must be called during component initialisation.
*
* @param {any} key
* @returns {boolean}
*/
function hasContext(key) {
	return get_or_init_context_map("hasContext").has(key);
}
/**
* @param {Record<string, unknown>} props
* @param {any} runes
* @param {Function} [fn]
* @returns {void}
*/
function push(props, runes = false, fn) {
	component_context = {
		p: component_context,
		i: false,
		c: null,
		e: null,
		s: props,
		x: null,
		r: active_effect,
		l: legacy_mode_flag && !runes ? {
			s: null,
			u: null,
			$: []
		} : null
	};
}
/**
* @template {Record<string, any>} T
* @param {T} [component]
* @returns {T}
*/
function pop(component) {
	var context = component_context;
	var effects = context.e;
	if (effects !== null) {
		context.e = null;
		for (var fn of effects) create_user_effect(fn);
	}
	if (component !== void 0) context.x = component;
	context.i = true;
	component_context = context.p;
	return component ?? {};
}
/** @returns {boolean} */
function is_runes() {
	return !legacy_mode_flag || component_context !== null && component_context.l === null;
}
/**
* @param {string} name
* @returns {Map<unknown, unknown>}
*/
function get_or_init_context_map(name) {
	if (component_context === null) lifecycle_outside_component(name);
	return component_context.c ??= new Map(get_parent_context(component_context) || void 0);
}
/**
* @param {ComponentContext} component_context
* @returns {Map<unknown, unknown> | null}
*/
function get_parent_context(component_context) {
	let parent = component_context.p;
	while (parent !== null) {
		const context_map = parent.c;
		if (context_map !== null) return context_map;
		parent = parent.p;
	}
	return null;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/task.js
/** @type {Array<() => void>} */
var micro_tasks = [];
function run_micro_tasks() {
	var tasks = micro_tasks;
	micro_tasks = [];
	run_all(tasks);
}
/**
* @param {() => void} fn
*/
function queue_micro_task(fn) {
	if (micro_tasks.length === 0 && !is_flushing_sync) {
		var tasks = micro_tasks;
		queueMicrotask(() => {
			if (tasks === micro_tasks) run_micro_tasks();
		});
	}
	micro_tasks.push(fn);
}
/**
* Synchronously run any queued tasks.
*/
function flush_tasks() {
	while (micro_tasks.length > 0) run_micro_tasks();
}
/**
* @param {unknown} error
*/
function handle_error(error) {
	var effect = active_effect;
	if (effect === null) {
		/** @type {Derived} */ active_reaction.f |= ERROR_VALUE;
		return error;
	}
	if ((effect.f & 32768) === 0 && (effect.f & 4) === 0) throw error;
	invoke_error_boundary(error, effect);
}
/**
* @param {unknown} error
* @param {Effect | null} effect
*/
function invoke_error_boundary(error, effect) {
	while (effect !== null) {
		if ((effect.f & 128) !== 0) {
			if ((effect.f & 32768) === 0) throw error;
			try {
				/** @type {Boundary} */ effect.b.error(error);
				return;
			} catch (e) {
				error = e;
			}
		}
		effect = effect.parent;
	}
	throw error;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/status.js
/** @import { Derived, Signal } from '#client' */
var STATUS_MASK = ~(DIRTY | MAYBE_DIRTY | CLEAN);
/**
* @param {Signal} signal
* @param {number} status
*/
function set_signal_status(signal, status) {
	signal.f = signal.f & STATUS_MASK | status;
}
/**
* Set a derived's status to CLEAN or MAYBE_DIRTY based on its connection state.
* @param {Derived} derived
*/
function update_derived_status(derived) {
	if ((derived.f & 512) !== 0 || derived.deps === null) set_signal_status(derived, CLEAN);
	else set_signal_status(derived, MAYBE_DIRTY);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/utils.js
/** @import { Derived, Effect, Value } from '#client' */
/**
* @param {Value[] | null} deps
*/
function clear_marked(deps) {
	if (deps === null) return;
	for (const dep of deps) {
		if ((dep.f & 2) === 0 || (dep.f & 65536) === 0) continue;
		dep.f ^= WAS_MARKED;
		clear_marked(
			/** @type {Derived} */
			dep.deps
		);
	}
}
/**
* @param {Effect} effect
* @param {Set<Effect>} dirty_effects
* @param {Set<Effect>} maybe_dirty_effects
*/
function defer_effect(effect, dirty_effects, maybe_dirty_effects) {
	if ((effect.f & 2048) !== 0) dirty_effects.add(effect);
	else if ((effect.f & 4096) !== 0) maybe_dirty_effects.add(effect);
	clear_marked(effect.deps);
	set_signal_status(effect, CLEAN);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/store.js
/**
* We set this to `true` when updating a store so that we correctly
* schedule effects if the update takes place inside a `$:` effect
*/
var legacy_is_updating_store = false;
/**
* Whether or not the prop currently being read is a store binding, as in
* `<Child bind:x={$y} />`. If it is, we treat the prop as mutable even in
* runes mode, and skip `binding_property_non_reactive` validation
*/
var is_store_binding = false;
/**
* Returns a tuple that indicates whether `fn()` reads a prop that is a store binding.
* Used to prevent `binding_property_non_reactive` validation false positives and
* ensure that these props are treated as mutable even in runes mode
* @template T
* @param {() => T} fn
* @returns {[T, boolean]}
*/
function capture_store_binding(fn) {
	var previous_is_store_binding = is_store_binding;
	try {
		is_store_binding = false;
		return [fn(), is_store_binding];
	} finally {
		is_store_binding = previous_is_store_binding;
	}
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/batch.js
/** @import { Fork } from 'svelte' */
/** @import { Derived, Effect, Reaction, Source, Value } from '#client' */
/** @type {Batch | null} */
var first_batch = null;
/** @type {Batch | null} */
var last_batch = null;
/** @type {Batch | null} */
var current_batch = null;
/**
* This is needed to avoid overwriting inputs
* @type {Batch | null}
*/
var previous_batch = null;
/**
* When time travelling (i.e. working in one batch, while other batches
* still have ongoing work), we ignore the real values of affected
* signals in favour of their values within the batch
* @type {Map<Value, any> | null}
*/
var batch_values = null;
/** @type {Effect | null} */
var last_scheduled_effect = null;
var is_flushing_sync = false;
var is_processing = false;
/**
* During traversal, this is an array. Newly created effects are (if not immediately
* executed) pushed to this array, rather than going through the scheduling
* rigamarole that would cause another turn of the flush loop.
* @type {Effect[] | null}
*/
var collected_effects = null;
/**
* An array of effects that are marked during traversal as a result of a `set`
* (not `internal_set`) call. These will be added to the next batch and
* trigger another `batch.process()`
* @type {Effect[] | null}
* @deprecated when we get rid of legacy mode and stores, we can get rid of this
*/
var legacy_updates = null;
var flush_count = 0;
var uid = 1;
var Batch = class Batch {
	id = uid++;
	/** True as soon as `#process` was called */
	#started = false;
	linked = true;
	/** @type {Batch | null} */
	#prev = null;
	/** @type {Batch | null} */
	#next = null;
	/** @type {Map<Effect, ReturnType<typeof deferred<any>>>} */
	async_deriveds = /* @__PURE__ */ new Map();
	/**
	* The current values of any signals that are updated in this batch.
	* Tuple format: [value, is_derived] (note: is_derived is false for deriveds, too, if they were overridden via assignment)
	* They keys of this map are identical to `this.#previous`
	* @type {Map<Value, [any, boolean]>}
	*/
	current = /* @__PURE__ */ new Map();
	/**
	* The values of any signals (sources and deriveds) that are updated in this batch _before_ those updates took place.
	* They keys of this map are identical to `this.#current`
	* @type {Map<Value, any>}
	*/
	previous = /* @__PURE__ */ new Map();
	/**
	* Async effects which this batch doesn't take into account anymore when calculating blockers,
	* as it has a value for it already.
	* @type {Set<Effect>}
	*/
	unblocked = /* @__PURE__ */ new Set();
	/**
	* When the batch is committed (and the DOM is updated), we need to remove old branches
	* and append new ones by calling the functions added inside (if/each/key/etc) blocks
	* @type {Set<(batch: Batch) => void>}
	*/
	#commit_callbacks = /* @__PURE__ */ new Set();
	/**
	* If a fork is discarded, we need to destroy any effects that are no longer needed
	* @type {Set<(batch: Batch) => void>}
	*/
	#discard_callbacks = /* @__PURE__ */ new Set();
	/**
	* Callbacks that should run only when a fork is committed.
	* @type {Set<(batch: Batch) => void>}
	*/
	#fork_commit_callbacks = /* @__PURE__ */ new Set();
	/**
	* The number of async effects that are currently in flight
	*/
	#pending = 0;
	/**
	* Async effects that are currently in flight, _not_ inside a pending boundary
	* @type {Map<Effect, number>}
	*/
	#blocking_pending = /* @__PURE__ */ new Map();
	/**
	* A deferred that resolves when the batch is committed, used with `settled()`
	* TODO replace with Promise.withResolvers once supported widely enough
	* @type {{ promise: Promise<void>, resolve: (value?: any) => void, reject: (reason: unknown) => void } | null}
	*/
	#deferred = null;
	/**
	* The root effects that need to be flushed
	* @type {Effect[]}
	*/
	#roots = [];
	/**
	* Effects created while this batch was active.
	* @type {Effect[]}
	*/
	#new_effects = [];
	/**
	* Deferred effects (which run after async work has completed) that are DIRTY
	* @type {Set<Effect>}
	*/
	#dirty_effects = /* @__PURE__ */ new Set();
	/**
	* Deferred effects that are MAYBE_DIRTY
	* @type {Set<Effect>}
	*/
	#maybe_dirty_effects = /* @__PURE__ */ new Set();
	/**
	* A map of branches that still exist, but will be destroyed when this batch
	* is committed — we skip over these during `process`.
	* The value contains child effects that were dirty/maybe_dirty before being reset,
	* so they can be rescheduled if the branch survives.
	* @type {Map<Effect, { d: Effect[], m: Effect[] }>}
	*/
	#skipped_branches = /* @__PURE__ */ new Map();
	/**
	* Inverse of #skipped_branches which we need to tell prior batches to unskip them when committing
	* @type {Set<Effect>}
	*/
	#unskipped_branches = /* @__PURE__ */ new Set();
	is_fork = false;
	#decrement_queued = false;
	#is_deferred() {
		if (this.is_fork) return true;
		for (const effect of this.#blocking_pending.keys()) {
			var e = effect;
			var skipped = false;
			while (e.parent !== null) {
				if (this.#skipped_branches.has(e)) {
					skipped = true;
					break;
				}
				e = e.parent;
			}
			if (!skipped) return true;
		}
		return false;
	}
	/**
	* Add an effect to the #skipped_branches map and reset its children
	* @param {Effect} effect
	*/
	skip_effect(effect) {
		if (!this.#skipped_branches.has(effect)) this.#skipped_branches.set(effect, {
			d: [],
			m: []
		});
		this.#unskipped_branches.delete(effect);
	}
	/**
	* Remove an effect from the #skipped_branches map and reschedule
	* any tracked dirty/maybe_dirty child effects
	* @param {Effect} effect
	* @param {(e: Effect) => void} callback
	*/
	unskip_effect(effect, callback = (e) => this.schedule(e)) {
		var tracked = this.#skipped_branches.get(effect);
		if (tracked) {
			this.#skipped_branches.delete(effect);
			for (var e of tracked.d) {
				set_signal_status(e, DIRTY);
				callback(e);
			}
			for (e of tracked.m) {
				set_signal_status(e, MAYBE_DIRTY);
				callback(e);
			}
		}
		this.#unskipped_branches.add(effect);
	}
	#process() {
		this.#started = true;
		if (flush_count++ > 1e3) {
			this.#unlink();
			infinite_loop_guard();
		}
		if (!this.#is_deferred()) {
			for (const e of this.#dirty_effects) {
				this.#maybe_dirty_effects.delete(e);
				set_signal_status(e, DIRTY);
				this.schedule(e);
			}
			for (const e of this.#maybe_dirty_effects) {
				set_signal_status(e, MAYBE_DIRTY);
				this.schedule(e);
			}
		}
		const roots = this.#roots;
		this.#roots = [];
		this.apply();
		/** @type {Effect[]} */
		var effects = collected_effects = [];
		/** @type {Effect[]} */
		var render_effects = [];
		/**
		* @type {Effect[]}
		* @deprecated when we get rid of legacy mode and stores, we can get rid of this
		*/
		var updates = legacy_updates = [];
		for (const root of roots) try {
			this.#traverse(root, effects, render_effects);
		} catch (e) {
			reset_all(root);
			throw e;
		}
		current_batch = null;
		if (updates.length > 0) {
			var batch = Batch.ensure();
			for (const e of updates) batch.schedule(e);
		}
		collected_effects = null;
		legacy_updates = null;
		if (this.#is_deferred()) {
			this.#defer_effects(render_effects);
			this.#defer_effects(effects);
			for (const [e, t] of this.#skipped_branches) reset_branch(e, t);
			if (updates.length > 0)
 /** @type {Batch} */ current_batch.#process();
			return;
		}
		const earlier_batch = this.#find_earlier_batch();
		if (earlier_batch) {
			earlier_batch.#merge(this);
			return;
		}
		this.#dirty_effects.clear();
		this.#maybe_dirty_effects.clear();
		for (const fn of this.#commit_callbacks) fn(this);
		this.#commit_callbacks.clear();
		previous_batch = this;
		flush_queued_effects(render_effects);
		flush_queued_effects(effects);
		previous_batch = null;
		this.#deferred?.resolve();
		var next_batch = current_batch;
		if (this.linked && this.#pending === 0) this.#unlink();
		if (async_mode_flag && !this.linked) {
			this.#commit();
			current_batch = next_batch;
		}
		if (this.#roots.length > 0) {
			if (next_batch === null) {
				next_batch = this;
				this.#link();
			}
			const batch = next_batch;
			batch.#roots.push(...this.#roots.filter((r) => !batch.#roots.includes(r)));
		}
		if (next_batch !== null) next_batch.#process();
	}
	/**
	* Traverse the effect tree, executing effects or stashing
	* them for later execution as appropriate
	* @param {Effect} root
	* @param {Effect[]} effects
	* @param {Effect[]} render_effects
	*/
	#traverse(root, effects, render_effects) {
		root.f ^= CLEAN;
		var effect = root.first;
		while (effect !== null) {
			var flags = effect.f;
			var is_branch = (flags & 96) !== 0;
			if (!(is_branch && (flags & 1024) !== 0 || (flags & 8192) !== 0 || this.#skipped_branches.has(effect)) && effect.fn !== null) {
				if (is_branch) effect.f ^= CLEAN;
				else if ((flags & 4) !== 0) effects.push(effect);
				else if (async_mode_flag && (flags & 16777224) !== 0) render_effects.push(effect);
				else if (is_dirty(effect)) {
					if ((flags & 16) !== 0) this.#maybe_dirty_effects.add(effect);
					update_effect(effect);
				}
				var child = effect.first;
				if (child !== null) {
					effect = child;
					continue;
				}
			}
			while (effect !== null) {
				var next = effect.next;
				if (next !== null) {
					effect = next;
					break;
				}
				effect = effect.parent;
			}
		}
	}
	#find_earlier_batch() {
		var batch = this.#prev;
		while (batch !== null) {
			if (!batch.is_fork) {
				for (const [value, [, is_derived]] of this.current) if (batch.current.has(value) && !is_derived) return batch;
			}
			batch = batch.#prev;
		}
		return null;
	}
	/**
	* @param {Batch} batch
	*/
	#merge(batch) {
		for (const [source, value] of batch.current) {
			if (!this.previous.has(source) && batch.previous.has(source)) this.previous.set(source, batch.previous.get(source));
			this.current.set(source, value);
		}
		for (const [effect, deferred] of batch.async_deriveds) {
			const d = this.async_deriveds.get(effect);
			if (d) deferred.promise.then(d.resolve);
		}
		/**
		* mark all effects that depend on `batch.current`, except the
		* async effects that we just resolved (TODO unless they depend
		* on values in this batch that are NOT in the later batch?).
		* Through this we also will populate the correct #skipped_branches,
		* oncommit callbacks etc, so we don't need to merge them separately.
		* @param {Value} value
		*/
		const mark = (value) => {
			var reactions = value.reactions;
			if (reactions === null) return;
			for (const reaction of reactions) {
				var flags = reaction.f;
				if ((flags & 2) !== 0) mark(reaction);
				else {
					var effect = reaction;
					if (flags & 4194320 && !this.async_deriveds.has(effect)) {
						this.#maybe_dirty_effects.delete(effect);
						set_signal_status(effect, DIRTY);
						this.schedule(effect);
					}
				}
			}
		};
		for (const source of this.current.keys()) mark(source);
		this.oncommit(() => batch.discard());
		batch.#unlink();
		current_batch = this;
		this.#process();
	}
	/**
	* @param {Effect[]} effects
	*/
	#defer_effects(effects) {
		for (var i = 0; i < effects.length; i += 1) defer_effect(effects[i], this.#dirty_effects, this.#maybe_dirty_effects);
	}
	/**
	* Associate a change to a given source with the current
	* batch, noting its previous and current values
	* @param {Value} source
	* @param {any} value
	* @param {boolean} [is_derived]
	*/
	capture(source, value, is_derived = false) {
		if (source.v !== UNINITIALIZED && !this.previous.has(source)) this.previous.set(source, source.v);
		if ((source.f & 8388608) === 0) {
			this.current.set(source, [value, is_derived]);
			batch_values?.set(source, value);
		}
		if (!this.is_fork) source.v = value;
	}
	activate() {
		current_batch = this;
	}
	deactivate() {
		current_batch = null;
		batch_values = null;
	}
	flush() {
		try {
			is_processing = true;
			current_batch = this;
			this.#process();
		} finally {
			flush_count = 0;
			last_scheduled_effect = null;
			collected_effects = null;
			legacy_updates = null;
			is_processing = false;
			current_batch = null;
			batch_values = null;
			old_values.clear();
		}
	}
	discard() {
		for (const fn of this.#discard_callbacks) fn(this);
		this.#discard_callbacks.clear();
		this.#fork_commit_callbacks.clear();
		this.#unlink();
	}
	/**
	* @param {Effect} effect
	*/
	register_created_effect(effect) {
		this.#new_effects.push(effect);
	}
	#commit() {
		this.#unlink();
		for (let batch = first_batch; batch !== null; batch = batch.#next) {
			var is_earlier = batch.id < this.id;
			/** @type {Source[]} */
			var sources = [];
			for (const [source, [value, is_derived]] of this.current) {
				if (batch.current.has(source)) {
					var batch_value = batch.current.get(source)[0];
					if (is_earlier && value !== batch_value) batch.current.set(source, [value, is_derived]);
					else continue;
				}
				sources.push(source);
			}
			if (is_earlier) for (const [effect, deferred] of this.async_deriveds) {
				const d = batch.async_deriveds.get(effect);
				if (d) deferred.promise.then(d.resolve);
			}
			if (!batch.#started) continue;
			var others = [...batch.current.keys()].filter((s) => !this.current.has(s));
			if (others.length === 0) {
				if (is_earlier) batch.discard();
			} else if (sources.length > 0) {
				if (is_earlier) for (const unskipped of this.#unskipped_branches) batch.unskip_effect(unskipped, (e) => {
					if ((e.f & 4194320) !== 0) batch.schedule(e);
					else batch.#defer_effects([e]);
				});
				batch.activate();
				/** @type {Set<Value>} */
				var marked = /* @__PURE__ */ new Set();
				/** @type {Map<Reaction, boolean>} */
				var checked = /* @__PURE__ */ new Map();
				for (var source of sources) mark_effects(source, others, marked, checked);
				checked = /* @__PURE__ */ new Map();
				var current_unequal = [...batch.current.keys()].filter((c) => this.current.has(c) ? this.current.get(c)[0] !== c.v : true);
				if (current_unequal.length > 0) {
					for (const effect of this.#new_effects) if ((effect.f & 155648) === 0 && depends_on(effect, current_unequal, checked)) if ((effect.f & 4194320) !== 0) {
						set_signal_status(effect, DIRTY);
						batch.schedule(effect);
					} else batch.#dirty_effects.add(effect);
				}
				if (batch.#roots.length > 0) {
					batch.apply();
					for (var root of batch.#roots) batch.#traverse(root, [], []);
					batch.#roots = [];
				}
				batch.deactivate();
			}
		}
	}
	/**
	* @param {boolean} blocking
	* @param {Effect} effect
	*/
	increment(blocking, effect) {
		this.#pending += 1;
		if (blocking) {
			let blocking_pending_count = this.#blocking_pending.get(effect) ?? 0;
			this.#blocking_pending.set(effect, blocking_pending_count + 1);
		}
	}
	/**
	* @param {boolean} blocking
	* @param {Effect} effect
	*/
	decrement(blocking, effect) {
		this.#pending -= 1;
		if (blocking) {
			let blocking_pending_count = this.#blocking_pending.get(effect) ?? 0;
			if (blocking_pending_count === 1) this.#blocking_pending.delete(effect);
			else this.#blocking_pending.set(effect, blocking_pending_count - 1);
		}
		if (this.#decrement_queued) return;
		this.#decrement_queued = true;
		queue_micro_task(() => {
			this.#decrement_queued = false;
			if (this.linked) this.flush();
		});
	}
	/**
	* @param {Set<Effect>} dirty_effects
	* @param {Set<Effect>} maybe_dirty_effects
	*/
	transfer_effects(dirty_effects, maybe_dirty_effects) {
		for (const e of dirty_effects) this.#dirty_effects.add(e);
		for (const e of maybe_dirty_effects) this.#maybe_dirty_effects.add(e);
		dirty_effects.clear();
		maybe_dirty_effects.clear();
	}
	/** @param {(batch: Batch) => void} fn */
	oncommit(fn) {
		this.#commit_callbacks.add(fn);
	}
	/** @param {(batch: Batch) => void} fn */
	ondiscard(fn) {
		this.#discard_callbacks.add(fn);
	}
	/** @param {(batch: Batch) => void} fn */
	on_fork_commit(fn) {
		this.#fork_commit_callbacks.add(fn);
	}
	run_fork_commit_callbacks() {
		for (const fn of this.#fork_commit_callbacks) fn(this);
		this.#fork_commit_callbacks.clear();
	}
	settled() {
		return (this.#deferred ??= deferred()).promise;
	}
	static ensure() {
		if (current_batch === null) {
			const batch = current_batch = new Batch();
			batch.#link();
			if (!is_processing && !is_flushing_sync) queue_micro_task(() => {
				if (!batch.#started) batch.flush();
			});
		}
		return current_batch;
	}
	apply() {
		if (!async_mode_flag || !this.is_fork && this.#prev === null && this.#next === null) {
			batch_values = null;
			return;
		}
		batch_values = /* @__PURE__ */ new Map();
		for (const [source, [value]] of this.current) batch_values.set(source, value);
		for (let batch = first_batch; batch !== null; batch = batch.#next) {
			if (batch === this || batch.is_fork) continue;
			var intersects = false;
			if (batch.id < this.id) for (const [source, [, is_derived]] of batch.current) {
				if (is_derived) continue;
				if (this.current.has(source)) {
					intersects = true;
					break;
				}
			}
			if (!intersects) {
				for (const [source, previous] of batch.previous) if (!batch_values.has(source)) batch_values.set(source, previous);
			}
		}
	}
	/**
	*
	* @param {Effect} effect
	*/
	schedule(effect) {
		last_scheduled_effect = effect;
		if (effect.b?.is_pending && (effect.f & 16777228) !== 0 && (effect.f & 32768) === 0) {
			effect.b.defer_effect(effect);
			return;
		}
		var e = effect;
		while (e.parent !== null) {
			e = e.parent;
			var flags = e.f;
			if (collected_effects !== null && e === active_effect) {
				if (async_mode_flag) return;
				if ((active_reaction === null || (active_reaction.f & 2) === 0) && !legacy_is_updating_store) return;
			}
			if ((flags & 96) !== 0) {
				if ((flags & 1024) === 0) return;
				e.f ^= CLEAN;
			}
		}
		this.#roots.push(e);
	}
	#link() {
		if (last_batch === null) first_batch = last_batch = this;
		else {
			last_batch.#next = this;
			this.#prev = last_batch;
		}
		last_batch = this;
	}
	#unlink() {
		var prev = this.#prev;
		var next = this.#next;
		if (prev === null) first_batch = next;
		else prev.#next = next;
		if (next === null) last_batch = prev;
		else next.#prev = prev;
		this.linked = false;
	}
};
/**
* Synchronously flush any pending updates.
* Returns void if no callback is provided, otherwise returns the result of calling the callback.
* @template [T=void]
* @param {(() => T) | undefined} [fn]
* @returns {T}
*/
function flushSync(fn) {
	var was_flushing_sync = is_flushing_sync;
	is_flushing_sync = true;
	try {
		var result;
		if (fn) {
			if (current_batch !== null && !current_batch.is_fork) current_batch.flush();
			result = fn();
		}
		while (true) {
			flush_tasks();
			if (current_batch === null) return result;
			current_batch.flush();
		}
	} finally {
		is_flushing_sync = was_flushing_sync;
	}
}
function infinite_loop_guard() {
	try {
		effect_update_depth_exceeded();
	} catch (error) {
		invoke_error_boundary(error, last_scheduled_effect);
	}
}
/** @type {Set<Effect> | null} */
var eager_block_effects = null;
/**
* @param {Array<Effect>} effects
* @returns {void}
*/
function flush_queued_effects(effects) {
	var length = effects.length;
	if (length === 0) return;
	var i = 0;
	while (i < length) {
		var effect = effects[i++];
		if ((effect.f & 24576) === 0 && is_dirty(effect)) {
			eager_block_effects = /* @__PURE__ */ new Set();
			update_effect(effect);
			if (effect.deps === null && effect.first === null && effect.nodes === null && effect.teardown === null && effect.ac === null) unlink_effect(effect);
			if (eager_block_effects?.size > 0) {
				old_values.clear();
				for (const e of eager_block_effects) {
					if ((e.f & 24576) !== 0) continue;
					/** @type {Effect[]} */
					const ordered_effects = [e];
					let ancestor = e.parent;
					while (ancestor !== null) {
						if (eager_block_effects.has(ancestor)) {
							eager_block_effects.delete(ancestor);
							ordered_effects.push(ancestor);
						}
						ancestor = ancestor.parent;
					}
					for (let j = ordered_effects.length - 1; j >= 0; j--) {
						const e = ordered_effects[j];
						if ((e.f & 24576) !== 0) continue;
						update_effect(e);
					}
				}
				eager_block_effects.clear();
			}
		}
	}
	eager_block_effects = null;
}
/**
* This is similar to `mark_reactions`, but it only marks async/block effects
* depending on `value` and at least one of the other `sources`, so that
* these effects can re-run after another batch has been committed
* @param {Value} value
* @param {Source[]} sources
* @param {Set<Value>} marked
* @param {Map<Reaction, boolean>} checked
*/
function mark_effects(value, sources, marked, checked) {
	if (marked.has(value)) return;
	marked.add(value);
	if (value.reactions !== null) for (const reaction of value.reactions) {
		const flags = reaction.f;
		if ((flags & 2) !== 0) mark_effects(reaction, sources, marked, checked);
		else if ((flags & 4194320) !== 0 && (flags & 2048) === 0 && depends_on(reaction, sources, checked)) {
			set_signal_status(reaction, DIRTY);
			schedule_effect(reaction);
		}
	}
}
/**
* @param {Reaction} reaction
* @param {Source[]} sources
* @param {Map<Reaction, boolean>} checked
*/
function depends_on(reaction, sources, checked) {
	const depends = checked.get(reaction);
	if (depends !== void 0) return depends;
	if (reaction.deps !== null) for (const dep of reaction.deps) {
		if (includes.call(sources, dep)) return true;
		if ((dep.f & 2) !== 0 && depends_on(dep, sources, checked)) {
			checked.set(dep, true);
			return true;
		}
	}
	checked.set(reaction, false);
	return false;
}
/**
* @param {Effect} effect
* @returns {void}
*/
function schedule_effect(effect) {
	/** @type {Batch} */ current_batch.schedule(effect);
}
/**
* Mark all the effects inside a skipped branch CLEAN, so that
* they can be correctly rescheduled later. Tracks dirty and maybe_dirty
* effects so they can be rescheduled if the branch survives.
* @param {Effect} effect
* @param {{ d: Effect[], m: Effect[] }} tracked
*/
function reset_branch(effect, tracked) {
	if ((effect.f & 32) !== 0 && (effect.f & 1024) !== 0) return;
	if ((effect.f & 2048) !== 0) tracked.d.push(effect);
	else if ((effect.f & 4096) !== 0) tracked.m.push(effect);
	set_signal_status(effect, CLEAN);
	var e = effect.first;
	while (e !== null) {
		reset_branch(e, tracked);
		e = e.next;
	}
}
/**
* Mark an entire effect tree clean following an error
* @param {Effect} effect
*/
function reset_all(effect) {
	set_signal_status(effect, CLEAN);
	var e = effect.first;
	while (e !== null) {
		reset_all(e);
		e = e.next;
	}
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/reactivity/create-subscriber.js
/**
* Returns a `subscribe` function that integrates external event-based systems with Svelte's reactivity.
* It's particularly useful for integrating with web APIs like `MediaQuery`, `IntersectionObserver`, or `WebSocket`.
*
* If `subscribe` is called inside an effect (including indirectly, for example inside a getter),
* the `start` callback will be called with an `update` function. Whenever `update` is called, the effect re-runs.
*
* If `start` returns a cleanup function, it will be called when the effect is destroyed.
*
* If `subscribe` is called in multiple effects, `start` will only be called once as long as the effects
* are active, and the returned teardown function will only be called when all effects are destroyed.
*
* It's best understood with an example. Here's an implementation of [`MediaQuery`](https://svelte.dev/docs/svelte/svelte-reactivity#MediaQuery):
*
* ```js
* import { createSubscriber } from 'svelte/reactivity';
* import { on } from 'svelte/events';
*
* export class MediaQuery {
* 	#query;
* 	#subscribe;
*
* 	constructor(query) {
* 		this.#query = window.matchMedia(`(${query})`);
*
* 		this.#subscribe = createSubscriber((update) => {
* 			// when the `change` event occurs, re-run any effects that read `this.current`
* 			const off = on(this.#query, 'change', update);
*
* 			// stop listening when all the effects are destroyed
* 			return () => off();
* 		});
* 	}
*
* 	get current() {
* 		// This makes the getter reactive, if read in an effect
* 		this.#subscribe();
*
* 		// Return the current state of the query, whether or not we're in an effect
* 		return this.#query.matches;
* 	}
* }
* ```
* @param {(update: () => void) => (() => void) | void} start
* @since 5.7.0
*/
function createSubscriber(start) {
	let subscribers = 0;
	let version = source(0);
	/** @type {(() => void) | void} */
	let stop;
	return () => {
		if (effect_tracking()) {
			get(version);
			render_effect(() => {
				if (subscribers === 0) stop = untrack(() => start(() => increment(version)));
				subscribers += 1;
				return () => {
					queue_micro_task(() => {
						subscribers -= 1;
						if (subscribers === 0) {
							stop?.();
							stop = void 0;
							increment(version);
						}
					});
				};
			});
		}
	};
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/blocks/boundary.js
/** @import { Effect, Source, TemplateNode, } from '#client' */
/**
* @typedef {{
* 	 onerror?: ((error: unknown, reset: () => void) => void) | null;
*   failed?: ((anchor: Node, error: () => unknown, reset: () => () => void) => void) | null;
*   pending?: ((anchor: Node) => void) | null;
* }} BoundaryProps
*/
var flags = EFFECT_TRANSPARENT | EFFECT_PRESERVED;
/**
* @param {TemplateNode} node
* @param {BoundaryProps} props
* @param {((anchor: Node) => void)} children
* @param {((error: unknown) => unknown) | undefined} [transform_error]
* @returns {void}
*/
function boundary(node, props, children, transform_error) {
	new Boundary(node, props, children, transform_error);
}
var Boundary = class {
	/** @type {Boundary | null} */
	parent;
	is_pending = false;
	/**
	* API-level transformError transform function. Transforms errors before they reach the `failed` snippet.
	* Inherited from parent boundary, or defaults to identity.
	* @type {(error: unknown) => unknown}
	*/
	transform_error;
	/** @type {TemplateNode} */
	#anchor;
	/** @type {TemplateNode | null} */
	#hydrate_open = hydrating ? hydrate_node : null;
	/** @type {BoundaryProps} */
	#props;
	/** @type {((anchor: Node) => void)} */
	#children;
	/** @type {Effect} */
	#effect;
	/** @type {Effect | null} */
	#main_effect = null;
	/** @type {Effect | null} */
	#pending_effect = null;
	/** @type {Effect | null} */
	#failed_effect = null;
	/** @type {DocumentFragment | null} */
	#offscreen_fragment = null;
	#local_pending_count = 0;
	#pending_count = 0;
	#pending_count_update_queued = false;
	/** @type {Set<Effect>} */
	#dirty_effects = /* @__PURE__ */ new Set();
	/** @type {Set<Effect>} */
	#maybe_dirty_effects = /* @__PURE__ */ new Set();
	/**
	* A source containing the number of pending async deriveds/expressions.
	* Only created if `$effect.pending()` is used inside the boundary,
	* otherwise updating the source results in needless `Batch.ensure()`
	* calls followed by no-op flushes
	* @type {Source<number> | null}
	*/
	#effect_pending = null;
	#effect_pending_subscriber = createSubscriber(() => {
		this.#effect_pending = source(this.#local_pending_count);
		return () => {
			this.#effect_pending = null;
		};
	});
	/**
	* @param {TemplateNode} node
	* @param {BoundaryProps} props
	* @param {((anchor: Node) => void)} children
	* @param {((error: unknown) => unknown) | undefined} [transform_error]
	*/
	constructor(node, props, children, transform_error) {
		this.#anchor = node;
		this.#props = props;
		this.#children = (anchor) => {
			var effect = active_effect;
			effect.b = this;
			effect.f |= 128;
			children(anchor);
		};
		this.parent = active_effect.b;
		this.transform_error = transform_error ?? this.parent?.transform_error ?? ((e) => e);
		this.#effect = block(() => {
			if (hydrating) {
				const comment = this.#hydrate_open;
				hydrate_next();
				const server_rendered_pending = comment.data === "[!";
				if (comment.data.startsWith("[?")) {
					const serialized_error = JSON.parse(comment.data.slice(2));
					this.#hydrate_failed_content(serialized_error);
				} else if (server_rendered_pending) this.#hydrate_pending_content();
				else this.#hydrate_resolved_content();
			} else this.#render();
		}, flags);
		if (hydrating) this.#anchor = hydrate_node;
	}
	#hydrate_resolved_content() {
		try {
			this.#main_effect = branch(() => this.#children(this.#anchor));
		} catch (error) {
			this.error(error);
		}
	}
	/**
	* @param {unknown} error The deserialized error from the server's hydration comment
	*/
	#hydrate_failed_content(error) {
		const failed = this.#props.failed;
		if (!failed) return;
		this.#failed_effect = branch(() => {
			failed(this.#anchor, () => error, () => () => {});
		});
	}
	#hydrate_pending_content() {
		const pending = this.#props.pending;
		if (!pending) return;
		this.is_pending = true;
		this.#pending_effect = branch(() => pending(this.#anchor));
		queue_micro_task(() => {
			var fragment = this.#offscreen_fragment = document.createDocumentFragment();
			var anchor = create_text();
			fragment.append(anchor);
			this.#main_effect = this.#run(() => {
				return branch(() => this.#children(anchor));
			});
			if (this.#pending_count === 0) {
				this.#anchor.before(fragment);
				this.#offscreen_fragment = null;
				pause_effect(this.#pending_effect, () => {
					this.#pending_effect = null;
				});
				this.#resolve(current_batch);
			}
		});
	}
	#render() {
		try {
			this.is_pending = this.has_pending_snippet();
			this.#pending_count = 0;
			this.#local_pending_count = 0;
			this.#main_effect = branch(() => {
				this.#children(this.#anchor);
			});
			if (this.#pending_count > 0) {
				var fragment = this.#offscreen_fragment = document.createDocumentFragment();
				move_effect(this.#main_effect, fragment);
				const pending = this.#props.pending;
				this.#pending_effect = branch(() => pending(this.#anchor));
			} else this.#resolve(current_batch);
		} catch (error) {
			this.error(error);
		}
	}
	/**
	* @param {Batch} batch
	*/
	#resolve(batch) {
		this.is_pending = false;
		batch.transfer_effects(this.#dirty_effects, this.#maybe_dirty_effects);
	}
	/**
	* Defer an effect inside a pending boundary until the boundary resolves
	* @param {Effect} effect
	*/
	defer_effect(effect) {
		defer_effect(effect, this.#dirty_effects, this.#maybe_dirty_effects);
	}
	/**
	* Returns `false` if the effect exists inside a boundary whose pending snippet is shown
	* @returns {boolean}
	*/
	is_rendered() {
		return !this.is_pending && (!this.parent || this.parent.is_rendered());
	}
	has_pending_snippet() {
		return !!this.#props.pending;
	}
	/**
	* @template T
	* @param {() => T} fn
	*/
	#run(fn) {
		var previous_effect = active_effect;
		var previous_reaction = active_reaction;
		var previous_ctx = component_context;
		set_active_effect(this.#effect);
		set_active_reaction(this.#effect);
		set_component_context(this.#effect.ctx);
		try {
			Batch.ensure();
			return fn();
		} catch (e) {
			handle_error(e);
			return null;
		} finally {
			set_active_effect(previous_effect);
			set_active_reaction(previous_reaction);
			set_component_context(previous_ctx);
		}
	}
	/**
	* Updates the pending count associated with the currently visible pending snippet,
	* if any, such that we can replace the snippet with content once work is done
	* @param {1 | -1} d
	* @param {Batch} batch
	*/
	#update_pending_count(d, batch) {
		if (!this.has_pending_snippet()) {
			if (this.parent) this.parent.#update_pending_count(d, batch);
			return;
		}
		this.#pending_count += d;
		if (this.#pending_count === 0) {
			this.#resolve(batch);
			if (this.#pending_effect) pause_effect(this.#pending_effect, () => {
				this.#pending_effect = null;
			});
			if (this.#offscreen_fragment) {
				this.#anchor.before(this.#offscreen_fragment);
				this.#offscreen_fragment = null;
			}
		}
	}
	/**
	* Update the source that powers `$effect.pending()` inside this boundary,
	* and controls when the current `pending` snippet (if any) is removed.
	* Do not call from inside the class
	* @param {1 | -1} d
	* @param {Batch} batch
	*/
	update_pending_count(d, batch) {
		this.#update_pending_count(d, batch);
		this.#local_pending_count += d;
		if (!this.#effect_pending || this.#pending_count_update_queued) return;
		this.#pending_count_update_queued = true;
		queue_micro_task(() => {
			this.#pending_count_update_queued = false;
			if (this.#effect_pending) internal_set(this.#effect_pending, this.#local_pending_count);
		});
	}
	get_effect_pending() {
		this.#effect_pending_subscriber();
		return get(this.#effect_pending);
	}
	/** @param {unknown} error */
	error(error) {
		if (!this.#props.onerror && !this.#props.failed) throw error;
		if (current_batch?.is_fork) {
			if (this.#main_effect) current_batch.skip_effect(this.#main_effect);
			if (this.#pending_effect) current_batch.skip_effect(this.#pending_effect);
			if (this.#failed_effect) current_batch.skip_effect(this.#failed_effect);
			current_batch.on_fork_commit(() => {
				this.#handle_error(error);
			});
		} else this.#handle_error(error);
	}
	/**
	* @param {unknown} error
	*/
	#handle_error(error) {
		if (this.#main_effect) {
			destroy_effect(this.#main_effect);
			this.#main_effect = null;
		}
		if (this.#pending_effect) {
			destroy_effect(this.#pending_effect);
			this.#pending_effect = null;
		}
		if (this.#failed_effect) {
			destroy_effect(this.#failed_effect);
			this.#failed_effect = null;
		}
		if (hydrating) {
			set_hydrate_node(this.#hydrate_open);
			next();
			set_hydrate_node(skip_nodes());
		}
		var onerror = this.#props.onerror;
		let failed = this.#props.failed;
		var did_reset = false;
		var calling_on_error = false;
		const reset = () => {
			if (did_reset) {
				svelte_boundary_reset_noop();
				return;
			}
			did_reset = true;
			if (calling_on_error) svelte_boundary_reset_onerror();
			if (this.#failed_effect !== null) pause_effect(this.#failed_effect, () => {
				this.#failed_effect = null;
			});
			this.#run(() => {
				this.#render();
			});
		};
		/** @param {unknown} transformed_error */
		const handle_error_result = (transformed_error) => {
			try {
				calling_on_error = true;
				onerror?.(transformed_error, reset);
				calling_on_error = false;
			} catch (error) {
				invoke_error_boundary(error, this.#effect && this.#effect.parent);
			}
			if (failed) this.#failed_effect = this.#run(() => {
				try {
					return branch(() => {
						var effect = active_effect;
						effect.b = this;
						effect.f |= 128;
						failed(this.#anchor, () => transformed_error, () => reset);
					});
				} catch (error) {
					invoke_error_boundary(error, this.#effect.parent);
					return null;
				}
			});
		};
		queue_micro_task(() => {
			/** @type {unknown} */
			var result;
			try {
				result = this.transform_error(error);
			} catch (e) {
				invoke_error_boundary(e, this.#effect && this.#effect.parent);
				return;
			}
			if (result !== null && typeof result === "object" && typeof result.then === "function")
 /** @type {any} */ result.then(
				handle_error_result,
				/** @param {unknown} e */
				(e) => invoke_error_boundary(e, this.#effect && this.#effect.parent)
			);
			else handle_error_result(result);
		});
	}
};
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/async.js
/** @import { Blocker, Effect, Value } from '#client' */
/**
* @param {Blocker[]} blockers
* @param {Array<() => any>} sync
* @param {Array<() => Promise<any>>} async
* @param {(values: Value[]) => any} fn
*/
function flatten(blockers, sync, async, fn) {
	const d = is_runes() ? derived : derived_safe_equal;
	var pending = blockers.filter((b) => !b.settled);
	if (async.length === 0 && pending.length === 0) {
		fn(sync.map(d));
		return;
	}
	var parent = active_effect;
	var restore = capture();
	var blocker_promise = pending.length === 1 ? pending[0].promise : pending.length > 1 ? Promise.all(pending.map((b) => b.promise)) : null;
	/** @param {Value[]} values */
	function finish(values) {
		if ((parent.f & 16384) !== 0) return;
		restore();
		try {
			fn(values);
		} catch (error) {
			invoke_error_boundary(error, parent);
		}
		unset_context();
	}
	var decrement_pending = increment_pending();
	if (async.length === 0) {
		/** @type {Promise<any>} */ blocker_promise.then(() => finish(sync.map(d))).finally(decrement_pending);
		return;
	}
	function run() {
		Promise.all(async.map((expression) => /* @__PURE__ */ async_derived(expression))).then((result) => finish([...sync.map(d), ...result])).catch((error) => invoke_error_boundary(error, parent)).finally(decrement_pending);
	}
	if (blocker_promise) blocker_promise.then(() => {
		restore();
		run();
		unset_context();
	});
	else run();
}
/**
* Captures the current effect context so that we can restore it after
* some asynchronous work has happened (so that e.g. `await a + b`
* causes `b` to be registered as a dependency).
*/
function capture() {
	var previous_effect = active_effect;
	var previous_reaction = active_reaction;
	var previous_component_context = component_context;
	var previous_batch = current_batch;
	return function restore(activate_batch = true) {
		set_active_effect(previous_effect);
		set_active_reaction(previous_reaction);
		set_component_context(previous_component_context);
		if (activate_batch && (previous_effect.f & 16384) === 0) {
			previous_batch?.activate();
			previous_batch?.apply();
		}
	};
}
function unset_context(deactivate_batch = true) {
	set_active_effect(null);
	set_active_reaction(null);
	set_component_context(null);
	if (deactivate_batch) current_batch?.deactivate();
}
/**
* @returns {(skip?: boolean) => void}
*/
function increment_pending() {
	var effect = active_effect;
	var boundary = effect.b;
	var batch = current_batch;
	var blocking = boundary.is_rendered();
	boundary.update_pending_count(1, batch);
	batch.increment(blocking, effect);
	return () => {
		boundary.update_pending_count(-1, batch);
		batch.decrement(blocking, effect);
	};
}
/**
* @template V
* @param {() => V} fn
* @returns {Derived<V>}
*/
/* @__NO_SIDE_EFFECTS__ */
function derived(fn) {
	var flags = 2 | DIRTY;
	if (active_effect !== null) active_effect.f |= EFFECT_PRESERVED;
	return {
		ctx: component_context,
		deps: null,
		effects: null,
		equals,
		f: flags,
		fn,
		reactions: null,
		rv: 0,
		v: UNINITIALIZED,
		wv: 0,
		parent: active_effect,
		ac: null
	};
}
var OBSOLETE = Symbol("obsolete");
/**
* @template V
* @param {() => V | Promise<V>} fn
* @param {string} [label]
* @param {string} [location] If provided, print a warning if the value is not read immediately after update
* @returns {Promise<Source<V>>}
*/
/* @__NO_SIDE_EFFECTS__ */
function async_derived(fn, label, location) {
	let parent = active_effect;
	if (parent === null) async_derived_orphan();
	var promise = void 0;
	var signal = source(UNINITIALIZED);
	var should_suspend = !active_reaction;
	/** @type {Set<ReturnType<typeof deferred<V>>>} */
	var deferreds = /* @__PURE__ */ new Set();
	async_effect(() => {
		var effect = active_effect;
		/** @type {ReturnType<typeof deferred<V>>} */
		var d = deferred();
		promise = d.promise;
		try {
			Promise.resolve(fn()).then(d.resolve, (e) => {
				if (e !== STALE_REACTION) d.reject(e);
			}).finally(unset_context);
		} catch (error) {
			d.reject(error);
			unset_context();
		}
		var batch = current_batch;
		if (should_suspend) {
			if ((effect.f & 32768) !== 0) var decrement_pending = increment_pending();
			if (parent.b.is_rendered()) batch.async_deriveds.get(effect)?.reject(OBSOLETE);
			else for (const d of deferreds.values()) d.reject(OBSOLETE);
			deferreds.add(d);
			batch.async_deriveds.set(effect, d);
		}
		/**
		* @param {any} value
		* @param {unknown} error
		*/
		const handler = (value, error = void 0) => {
			decrement_pending?.();
			deferreds.delete(d);
			if (error === OBSOLETE) return;
			batch.activate();
			if (error) {
				signal.f |= ERROR_VALUE;
				internal_set(signal, error);
			} else {
				if ((signal.f & 8388608) !== 0) signal.f ^= ERROR_VALUE;
				internal_set(signal, value);
			}
			batch.deactivate();
		};
		d.promise.then(handler, (e) => handler(null, e || "unknown"));
	});
	teardown(() => {
		for (const d of deferreds) d.reject(OBSOLETE);
	});
	return new Promise((fulfil) => {
		/** @param {Promise<V>} p */
		function next(p) {
			function go() {
				if (p === promise) fulfil(signal);
				else next(promise);
			}
			p.then(go, go);
		}
		next(promise);
	});
}
/**
* @template V
* @param {() => V} fn
* @returns {Derived<V>}
*/
/* @__NO_SIDE_EFFECTS__ */
function user_derived(fn) {
	const d = /* @__PURE__ */ derived(fn);
	if (!async_mode_flag) push_reaction_value(d);
	return d;
}
/**
* @template V
* @param {() => V} fn
* @returns {Derived<V>}
*/
/* @__NO_SIDE_EFFECTS__ */
function derived_safe_equal(fn) {
	const signal = /* @__PURE__ */ derived(fn);
	signal.equals = safe_equals;
	return signal;
}
/**
* @param {Derived} derived
* @returns {void}
*/
function destroy_derived_effects(derived) {
	var effects = derived.effects;
	if (effects !== null) {
		derived.effects = null;
		for (var i = 0; i < effects.length; i += 1) destroy_effect(effects[i]);
	}
}
/**
* @template T
* @param {Derived} derived
* @returns {T}
*/
function execute_derived(derived) {
	var value;
	var prev_active_effect = active_effect;
	var parent = derived.parent;
	if (!is_destroying_effect && parent !== null && (parent.f & 24576) !== 0) {
		derived_inert();
		return derived.v;
	}
	set_active_effect(parent);
	try {
		derived.f &= ~WAS_MARKED;
		destroy_derived_effects(derived);
		value = update_reaction(derived);
	} finally {
		set_active_effect(prev_active_effect);
	}
	return value;
}
/**
* @param {Derived} derived
* @returns {void}
*/
function update_derived(derived) {
	var value = execute_derived(derived);
	if (!derived.equals(value)) {
		derived.wv = increment_write_version();
		if (!current_batch?.is_fork || derived.deps === null) {
			if (current_batch !== null) {
				current_batch.capture(derived, value, true);
				previous_batch?.capture(derived, value, true);
			} else derived.v = value;
			if (derived.deps === null) {
				set_signal_status(derived, CLEAN);
				return;
			}
		}
	}
	if (is_destroying_effect) return;
	if (batch_values !== null) {
		if (effect_tracking() || current_batch?.is_fork) batch_values.set(derived, value);
	} else update_derived_status(derived);
}
/**
* @param {Derived} derived
*/
function freeze_derived_effects(derived) {
	if (derived.effects === null) return;
	for (const e of derived.effects) if (e.teardown || e.ac) {
		e.teardown?.();
		e.ac?.abort(STALE_REACTION);
		e.teardown = noop$1;
		e.ac = null;
		remove_reactions(e, 0);
		destroy_effect_children(e);
	}
}
/**
* @param {Derived} derived
*/
function unfreeze_derived_effects(derived) {
	if (derived.effects === null) return;
	for (const e of derived.effects) if (e.teardown) update_effect(e);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/sources.js
/** @import { Derived, Effect, Source, Value } from '#client' */
/** @type {Set<Effect>} */
var eager_effects = /* @__PURE__ */ new Set();
/** @type {Map<Source, any>} */
var old_values = /* @__PURE__ */ new Map();
var eager_effects_deferred = false;
/**
* @template V
* @param {V} v
* @param {Error | null} [stack]
* @returns {Source<V>}
*/
function source(v, stack) {
	return {
		f: 0,
		v,
		reactions: null,
		equals,
		rv: 0,
		wv: 0
	};
}
/**
* @template V
* @param {V} v
* @param {Error | null} [stack]
*/
/* @__NO_SIDE_EFFECTS__ */
function state(v, stack) {
	const s = source(v, stack);
	push_reaction_value(s);
	return s;
}
/**
* @template V
* @param {V} initial_value
* @param {boolean} [immutable]
* @returns {Source<V>}
*/
/* @__NO_SIDE_EFFECTS__ */
function mutable_source(initial_value, immutable = false, trackable = true) {
	const s = source(initial_value);
	if (!immutable) s.equals = safe_equals;
	if (legacy_mode_flag && trackable && component_context !== null && component_context.l !== null) (component_context.l.s ??= []).push(s);
	return s;
}
/**
* @template V
* @param {Value<V>} source
* @param {V} value
*/
function mutate(source, value) {
	set(source, untrack(() => get(source)));
	return value;
}
/**
* @template V
* @param {Source<V>} source
* @param {V} value
* @param {boolean} [should_proxy]
* @returns {V}
*/
function set(source, value, should_proxy = false) {
	if (active_reaction !== null && (!untracking || (active_reaction.f & 131072) !== 0) && is_runes() && (active_reaction.f & 4325394) !== 0 && (current_sources === null || !includes.call(current_sources, source))) state_unsafe_mutation();
	return internal_set(source, should_proxy ? proxy(value) : value, legacy_updates);
}
/**
* @template V
* @param {Source<V>} source
* @param {V} value
* @param {Effect[] | null} [updated_during_traversal]
* @returns {V}
*/
function internal_set(source, value, updated_during_traversal = null) {
	if (!source.equals(value)) {
		old_values.set(source, is_destroying_effect ? value : source.v);
		var batch = Batch.ensure();
		batch.capture(source, value);
		if ((source.f & 2) !== 0) {
			const derived = source;
			if ((source.f & 2048) !== 0) execute_derived(derived);
			if (batch_values === null) update_derived_status(derived);
		}
		source.wv = increment_write_version();
		mark_reactions(source, DIRTY, updated_during_traversal);
		if (is_runes() && active_effect !== null && (active_effect.f & 1024) !== 0 && (active_effect.f & 96) === 0) if (untracked_writes === null) set_untracked_writes([source]);
		else untracked_writes.push(source);
		if (!batch.is_fork && eager_effects.size > 0 && !eager_effects_deferred) flush_eager_effects();
	}
	return value;
}
function flush_eager_effects() {
	eager_effects_deferred = false;
	for (const effect of eager_effects) {
		if ((effect.f & 1024) !== 0) set_signal_status(effect, MAYBE_DIRTY);
		let dirty;
		try {
			dirty = is_dirty(effect);
		} catch {
			dirty = true;
		}
		if (dirty) update_effect(effect);
	}
	eager_effects.clear();
}
/**
* Silently (without using `get`) increment a source
* @param {Source<number>} source
*/
function increment(source) {
	set(source, source.v + 1);
}
/**
* @param {Value} signal
* @param {number} status should be DIRTY or MAYBE_DIRTY
* @param {Effect[] | null} updated_during_traversal
* @returns {void}
*/
function mark_reactions(signal, status, updated_during_traversal) {
	var reactions = signal.reactions;
	if (reactions === null) return;
	var runes = is_runes();
	var length = reactions.length;
	for (var i = 0; i < length; i++) {
		var reaction = reactions[i];
		var flags = reaction.f;
		if (!runes && reaction === active_effect) continue;
		var not_dirty = (flags & DIRTY) === 0;
		if (not_dirty) set_signal_status(reaction, status);
		if ((flags & 131072) !== 0) eager_effects.add(reaction);
		else if ((flags & 2) !== 0) {
			var derived = reaction;
			batch_values?.delete(derived);
			if ((flags & 65536) === 0) {
				if (flags & 512 && (active_effect === null || (active_effect.f & 2097152) === 0)) reaction.f |= WAS_MARKED;
				mark_reactions(derived, MAYBE_DIRTY, updated_during_traversal);
			}
		} else if (not_dirty) {
			var effect = reaction;
			if ((flags & 16) !== 0 && eager_block_effects !== null) eager_block_effects.add(effect);
			if (updated_during_traversal !== null) updated_during_traversal.push(effect);
			else schedule_effect(effect);
		}
	}
}
/**
* @template T
* @param {T} value
* @returns {T}
*/
function proxy(value) {
	if (typeof value !== "object" || value === null || STATE_SYMBOL in value) return value;
	const prototype = get_prototype_of(value);
	if (prototype !== object_prototype && prototype !== array_prototype) return value;
	/** @type {Map<any, Source<any>>} */
	var sources = /* @__PURE__ */ new Map();
	var is_proxied_array = is_array(value);
	var version = /* @__PURE__ */ state(0);
	var stack = null;
	var parent_version = update_version;
	/**
	* Executes the proxy in the context of the reaction it was originally created in, if any
	* @template T
	* @param {() => T} fn
	*/
	var with_parent = (fn) => {
		if (update_version === parent_version) return fn();
		var reaction = active_reaction;
		var version = update_version;
		set_active_reaction(null);
		set_update_version(parent_version);
		var result = fn();
		set_active_reaction(reaction);
		set_update_version(version);
		return result;
	};
	if (is_proxied_array) sources.set("length", /* @__PURE__ */ state(
		/** @type {any[]} */
		value.length,
		stack
	));
	return new Proxy(value, {
		defineProperty(_, prop, descriptor) {
			if (!("value" in descriptor) || descriptor.configurable === false || descriptor.enumerable === false || descriptor.writable === false) state_descriptors_fixed();
			var s = sources.get(prop);
			if (s === void 0) with_parent(() => {
				var s = /* @__PURE__ */ state(descriptor.value, stack);
				sources.set(prop, s);
				return s;
			});
			else set(s, descriptor.value, true);
			return true;
		},
		deleteProperty(target, prop) {
			var s = sources.get(prop);
			if (s === void 0) {
				if (prop in target) {
					const s = with_parent(() => /* @__PURE__ */ state(UNINITIALIZED, stack));
					sources.set(prop, s);
					increment(version);
				}
			} else {
				set(s, UNINITIALIZED);
				increment(version);
			}
			return true;
		},
		get(target, prop, receiver) {
			if (prop === STATE_SYMBOL) return value;
			var s = sources.get(prop);
			var exists = prop in target;
			if (s === void 0 && (!exists || get_descriptor(target, prop)?.writable)) {
				s = with_parent(() => {
					return /* @__PURE__ */ state(proxy(exists ? target[prop] : UNINITIALIZED), stack);
				});
				sources.set(prop, s);
			}
			if (s !== void 0) {
				var v = get(s);
				return v === UNINITIALIZED ? void 0 : v;
			}
			return Reflect.get(target, prop, receiver);
		},
		getOwnPropertyDescriptor(target, prop) {
			var descriptor = Reflect.getOwnPropertyDescriptor(target, prop);
			if (descriptor && "value" in descriptor) {
				var s = sources.get(prop);
				if (s) descriptor.value = get(s);
			} else if (descriptor === void 0) {
				var source = sources.get(prop);
				var value = source?.v;
				if (source !== void 0 && value !== UNINITIALIZED) return {
					enumerable: true,
					configurable: true,
					value,
					writable: true
				};
			}
			return descriptor;
		},
		has(target, prop) {
			if (prop === STATE_SYMBOL) return true;
			var s = sources.get(prop);
			var has = s !== void 0 && s.v !== UNINITIALIZED || Reflect.has(target, prop);
			if (s !== void 0 || active_effect !== null && (!has || get_descriptor(target, prop)?.writable)) {
				if (s === void 0) {
					s = with_parent(() => {
						return /* @__PURE__ */ state(has ? proxy(target[prop]) : UNINITIALIZED, stack);
					});
					sources.set(prop, s);
				}
				if (get(s) === UNINITIALIZED) return false;
			}
			return has;
		},
		set(target, prop, value, receiver) {
			var s = sources.get(prop);
			var has = prop in target;
			if (is_proxied_array && prop === "length") for (var i = value; i < s.v; i += 1) {
				var other_s = sources.get(i + "");
				if (other_s !== void 0) set(other_s, UNINITIALIZED);
				else if (i in target) {
					other_s = with_parent(() => /* @__PURE__ */ state(UNINITIALIZED, stack));
					sources.set(i + "", other_s);
				}
			}
			if (s === void 0) {
				if (!has || get_descriptor(target, prop)?.writable) {
					s = with_parent(() => /* @__PURE__ */ state(void 0, stack));
					set(s, proxy(value));
					sources.set(prop, s);
				}
			} else {
				has = s.v !== UNINITIALIZED;
				var p = with_parent(() => proxy(value));
				set(s, p);
			}
			var descriptor = Reflect.getOwnPropertyDescriptor(target, prop);
			if (descriptor?.set) descriptor.set.call(receiver, value);
			if (!has) {
				if (is_proxied_array && typeof prop === "string") {
					var ls = sources.get("length");
					var n = Number(prop);
					if (Number.isInteger(n) && n >= ls.v) set(ls, n + 1);
				}
				increment(version);
			}
			return true;
		},
		ownKeys(target) {
			get(version);
			var own_keys = Reflect.ownKeys(target).filter((key) => {
				var source = sources.get(key);
				return source === void 0 || source.v !== UNINITIALIZED;
			});
			for (var [key, source] of sources) if (source.v !== UNINITIALIZED && !(key in target)) own_keys.push(key);
			return own_keys;
		},
		setPrototypeOf() {
			state_prototype_fixed();
		}
	});
}
/**
* @param {any} value
*/
function get_proxied_value(value) {
	try {
		if (value !== null && typeof value === "object" && STATE_SYMBOL in value) return value[STATE_SYMBOL];
	} catch {}
	return value;
}
/**
* @param {any} a
* @param {any} b
*/
function is(a, b) {
	return Object.is(get_proxied_value(a), get_proxied_value(b));
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/operations.js
/** @import { Effect, TemplateNode } from '#client' */
/** @type {Window} */
var $window;
/** @type {boolean} */
var is_firefox;
/** @type {() => Node | null} */
var first_child_getter;
/** @type {() => Node | null} */
var next_sibling_getter;
/**
* Initialize these lazily to avoid issues when using the runtime in a server context
* where these globals are not available while avoiding a separate server entry point
*/
function init_operations() {
	if ($window !== void 0) return;
	$window = window;
	is_firefox = /Firefox/.test(navigator.userAgent);
	var element_prototype = Element.prototype;
	var node_prototype = Node.prototype;
	var text_prototype = Text.prototype;
	first_child_getter = get_descriptor(node_prototype, "firstChild").get;
	next_sibling_getter = get_descriptor(node_prototype, "nextSibling").get;
	if (is_extensible(element_prototype)) {
		/** @type {any} */ element_prototype[CLASS_CACHE] = void 0;
		/** @type {any} */ element_prototype[ATTRIBUTES_CACHE] = null;
		/** @type {any} */ element_prototype[STYLE_CACHE] = void 0;
		element_prototype.__e = void 0;
	}
	if (is_extensible(text_prototype))
 /** @type {any} */ text_prototype[TEXT_CACHE] = void 0;
}
/**
* @param {string} value
* @returns {Text}
*/
function create_text(value = "") {
	return document.createTextNode(value);
}
/**
* @template {Node} N
* @param {N} node
*/
/* @__NO_SIDE_EFFECTS__ */
function get_first_child(node) {
	return first_child_getter.call(node);
}
/**
* @template {Node} N
* @param {N} node
*/
/* @__NO_SIDE_EFFECTS__ */
function get_next_sibling(node) {
	return next_sibling_getter.call(node);
}
/**
* Don't mark this as side-effect-free, hydration needs to walk all nodes
* @template {Node} N
* @param {N} node
* @param {boolean} is_text
* @returns {TemplateNode | null}
*/
function child(node, is_text) {
	if (!hydrating) return /* @__PURE__ */ get_first_child(node);
	var child = /* @__PURE__ */ get_first_child(hydrate_node);
	if (child === null) child = hydrate_node.appendChild(create_text());
	else if (is_text && child.nodeType !== 3) {
		var text = create_text();
		child?.before(text);
		set_hydrate_node(text);
		return text;
	}
	if (is_text) merge_text_nodes(child);
	set_hydrate_node(child);
	return child;
}
/**
* Don't mark this as side-effect-free, hydration needs to walk all nodes
* @param {TemplateNode} node
* @param {boolean} [is_text]
* @returns {TemplateNode | null}
*/
function first_child(node, is_text = false) {
	if (!hydrating) {
		var first = /* @__PURE__ */ get_first_child(node);
		if (first instanceof Comment && first.data === "") return /* @__PURE__ */ get_next_sibling(first);
		return first;
	}
	if (is_text) {
		if (hydrate_node?.nodeType !== 3) {
			var text = create_text();
			hydrate_node?.before(text);
			set_hydrate_node(text);
			return text;
		}
		merge_text_nodes(hydrate_node);
	}
	return hydrate_node;
}
/**
* Don't mark this as side-effect-free, hydration needs to walk all nodes
* @param {TemplateNode} node
* @param {number} count
* @param {boolean} is_text
* @returns {TemplateNode | null}
*/
function sibling(node, count = 1, is_text = false) {
	let next_sibling = hydrating ? hydrate_node : node;
	var last_sibling;
	while (count--) {
		last_sibling = next_sibling;
		next_sibling = /* @__PURE__ */ get_next_sibling(next_sibling);
	}
	if (!hydrating) return next_sibling;
	if (is_text) {
		if (next_sibling?.nodeType !== 3) {
			var text = create_text();
			if (next_sibling === null) last_sibling?.after(text);
			else next_sibling.before(text);
			set_hydrate_node(text);
			return text;
		}
		merge_text_nodes(next_sibling);
	}
	set_hydrate_node(next_sibling);
	return next_sibling;
}
/**
* Returns `true` if we're updating the current block, for example `condition` in
* an `{#if condition}` block just changed. In this case, the branch should be
* appended (or removed) at the same time as other updates within the
* current `<svelte:boundary>`
*/
function should_defer_append() {
	if (!async_mode_flag) return false;
	if (eager_block_effects !== null) return false;
	return (active_effect.f & REACTION_RAN) !== 0;
}
/**
* @template {keyof HTMLElementTagNameMap | string} T
* @param {T} tag
* @param {string} [namespace]
* @param {string} [is]
* @returns {T extends keyof HTMLElementTagNameMap ? HTMLElementTagNameMap[T] : Element}
*/
function create_element(tag, namespace, is) {
	let options = is ? { is } : void 0;
	return document.createElementNS(namespace ?? "http://www.w3.org/1999/xhtml", tag, options);
}
/**
* Browsers split text nodes larger than 65536 bytes when parsing.
* For hydration to succeed, we need to stitch them back together
* @param {Text} text
*/
function merge_text_nodes(text) {
	if (text.nodeValue.length < 65536) return;
	let next = text.nextSibling;
	while (next !== null && next.nodeType === 3) {
		next.remove();
		/** @type {string} */ text.nodeValue += next.nodeValue;
		next = text.nextSibling;
	}
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/misc.js
/**
* @param {HTMLElement} dom
* @param {boolean} value
* @returns {void}
*/
function autofocus(dom, value) {
	if (value) {
		const body = document.body;
		dom.autofocus = true;
		queue_micro_task(() => {
			if (document.activeElement === body) dom.focus();
		});
	}
}
var listening_to_form_reset = false;
function add_form_reset_listener() {
	if (!listening_to_form_reset) {
		listening_to_form_reset = true;
		document.addEventListener("reset", (evt) => {
			Promise.resolve().then(() => {
				if (!evt.defaultPrevented) for (const e of evt.target.elements)
 /** @type {any} */ e[FORM_RESET_HANDLER]?.();
			});
		}, { capture: true });
	}
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/bindings/shared.js
/**
* @template T
* @param {() => T} fn
*/
function without_reactive_context(fn) {
	var previous_reaction = active_reaction;
	var previous_effect = active_effect;
	set_active_reaction(null);
	set_active_effect(null);
	try {
		return fn();
	} finally {
		set_active_reaction(previous_reaction);
		set_active_effect(previous_effect);
	}
}
/**
* Listen to the given event, and then instantiate a global form reset listener if not already done,
* to notify all bindings when the form is reset
* @param {HTMLElement} element
* @param {string} event
* @param {(is_reset?: true) => void} handler
* @param {(is_reset?: true) => void} [on_reset]
*/
function listen_to_event_and_reset_event(element, event, handler, on_reset = handler) {
	element.addEventListener(event, () => without_reactive_context(handler));
	const prev = element[FORM_RESET_HANDLER];
	if (prev)
 /** @type {any} */ element[FORM_RESET_HANDLER] = () => {
		prev();
		on_reset(true);
	};
	else
 /** @type {any} */ element[FORM_RESET_HANDLER] = () => on_reset(true);
	add_form_reset_listener();
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/effects.js
/** @import { Blocker, ComponentContext, ComponentContextLegacy, Derived, Effect, TemplateNode, TransitionManager } from '#client' */
/**
* @param {'$effect' | '$effect.pre' | '$inspect'} rune
*/
function validate_effect(rune) {
	if (active_effect === null) {
		if (active_reaction === null) effect_orphan(rune);
		effect_in_unowned_derived();
	}
	if (is_destroying_effect) effect_in_teardown(rune);
}
/**
* @param {Effect} effect
* @param {Effect} parent_effect
*/
function push_effect(effect, parent_effect) {
	var parent_last = parent_effect.last;
	if (parent_last === null) parent_effect.last = parent_effect.first = effect;
	else {
		parent_last.next = effect;
		effect.prev = parent_last;
		parent_effect.last = effect;
	}
}
/**
* @param {number} type
* @param {null | (() => void | (() => void))} fn
* @returns {Effect}
*/
function create_effect(type, fn) {
	var parent = active_effect;
	if (parent !== null && (parent.f & 8192) !== 0) type |= INERT;
	/** @type {Effect} */
	var effect = {
		ctx: component_context,
		deps: null,
		nodes: null,
		f: type | DIRTY | 512,
		first: null,
		fn,
		last: null,
		next: null,
		parent,
		b: parent && parent.b,
		prev: null,
		teardown: null,
		wv: 0,
		ac: null
	};
	current_batch?.register_created_effect(effect);
	/** @type {Effect | null} */
	var e = effect;
	if ((type & 4) !== 0) if (collected_effects !== null) collected_effects.push(effect);
	else Batch.ensure().schedule(effect);
	else if (fn !== null) {
		try {
			update_effect(effect);
		} catch (e) {
			destroy_effect(effect);
			throw e;
		}
		if (e.deps === null && e.teardown === null && e.nodes === null && e.first === e.last && (e.f & 524288) === 0) {
			e = e.first;
			if ((type & 16) !== 0 && (type & 65536) !== 0 && e !== null) e.f |= EFFECT_TRANSPARENT;
		}
	}
	if (e !== null) {
		e.parent = parent;
		if (parent !== null) push_effect(e, parent);
		if (active_reaction !== null && (active_reaction.f & 2) !== 0 && (type & 64) === 0) {
			var derived = active_reaction;
			(derived.effects ??= []).push(e);
		}
	}
	return effect;
}
/**
* Internal representation of `$effect.tracking()`
* @returns {boolean}
*/
function effect_tracking() {
	return active_reaction !== null && !untracking;
}
/**
* @param {() => void} fn
*/
function teardown(fn) {
	const effect = create_effect(8, null);
	set_signal_status(effect, CLEAN);
	effect.teardown = fn;
	return effect;
}
/**
* Internal representation of `$effect(...)`
* @param {() => void | (() => void)} fn
*/
function user_effect(fn) {
	validate_effect("$effect");
	var flags = active_effect.f;
	if (!active_reaction && (flags & 32) !== 0 && (flags & 32768) === 0) {
		var context = component_context;
		(context.e ??= []).push(fn);
	} else return create_user_effect(fn);
}
/**
* @param {() => void | (() => void)} fn
*/
function create_user_effect(fn) {
	return create_effect(4 | USER_EFFECT, fn);
}
/**
* Internal representation of `$effect.pre(...)`
* @param {() => void | (() => void)} fn
* @returns {Effect}
*/
function user_pre_effect(fn) {
	validate_effect("$effect.pre");
	return create_effect(8 | USER_EFFECT, fn);
}
/**
* Internal representation of `$effect.root(...)`
* @param {() => void | (() => void)} fn
* @returns {() => void}
*/
function effect_root(fn) {
	Batch.ensure();
	const effect = create_effect(64 | EFFECT_PRESERVED, fn);
	return () => {
		destroy_effect(effect);
	};
}
/**
* An effect root whose children can transition out
* @param {() => void} fn
* @returns {(options?: { outro?: boolean }) => Promise<void>}
*/
function component_root(fn) {
	Batch.ensure();
	const effect = create_effect(64 | EFFECT_PRESERVED, fn);
	return (options = {}) => {
		return new Promise((fulfil) => {
			if (options.outro) pause_effect(effect, () => {
				destroy_effect(effect);
				fulfil(void 0);
			});
			else {
				destroy_effect(effect);
				fulfil(void 0);
			}
		});
	};
}
/**
* @param {() => void | (() => void)} fn
* @returns {Effect}
*/
function effect(fn) {
	return create_effect(4, fn);
}
/**
* Internal representation of `$: ..`
* @param {() => any} deps
* @param {() => void | (() => void)} fn
*/
function legacy_pre_effect(deps, fn) {
	var context = component_context;
	/** @type {{ effect: null | Effect, ran: boolean, deps: () => any }} */
	var token = {
		effect: null,
		ran: false,
		deps
	};
	context.l.$.push(token);
	token.effect = render_effect(() => {
		deps();
		if (token.ran) return;
		token.ran = true;
		var effect = active_effect;
		try {
			set_active_effect(effect.parent);
			untrack(fn);
		} finally {
			set_active_effect(effect);
		}
	});
}
function legacy_pre_effect_reset() {
	var context = component_context;
	render_effect(() => {
		for (var token of context.l.$) {
			token.deps();
			var effect = token.effect;
			if ((effect.f & 1024) !== 0 && effect.deps !== null) set_signal_status(effect, MAYBE_DIRTY);
			if (is_dirty(effect)) update_effect(effect);
			token.ran = false;
		}
	});
}
/**
* @param {() => void | (() => void)} fn
* @returns {Effect}
*/
function async_effect(fn) {
	return create_effect(ASYNC | EFFECT_PRESERVED, fn);
}
/**
* @param {() => void | (() => void)} fn
* @returns {Effect}
*/
function render_effect(fn, flags = 0) {
	return create_effect(8 | flags, fn);
}
/**
* @param {(...expressions: any) => void | (() => void)} fn
* @param {Array<() => any>} sync
* @param {Array<() => Promise<any>>} async
* @param {Blocker[]} blockers
*/
function template_effect(fn, sync = [], async = [], blockers = []) {
	flatten(blockers, sync, async, (values) => {
		create_effect(8, () => fn(...values.map(get)));
	});
}
/**
* @param {(() => void)} fn
* @param {number} flags
*/
function block(fn, flags = 0) {
	return create_effect(16 | flags, fn);
}
/**
* @param {(() => void)} fn
* @param {number} flags
*/
function managed(fn, flags = 0) {
	return create_effect(MANAGED_EFFECT | flags, fn);
}
/**
* @param {(() => void)} fn
*/
function branch(fn) {
	return create_effect(32 | EFFECT_PRESERVED, fn);
}
/**
* @param {Effect} effect
*/
function execute_effect_teardown(effect) {
	var teardown = effect.teardown;
	if (teardown !== null) {
		const previously_destroying_effect = is_destroying_effect;
		const previous_reaction = active_reaction;
		set_is_destroying_effect(true);
		set_active_reaction(null);
		try {
			teardown.call(null);
		} finally {
			set_is_destroying_effect(previously_destroying_effect);
			set_active_reaction(previous_reaction);
		}
	}
}
/**
* @param {Effect} signal
* @param {boolean} remove_dom
* @returns {void}
*/
function destroy_effect_children(signal, remove_dom = false) {
	var effect = signal.first;
	signal.first = signal.last = null;
	while (effect !== null) {
		const controller = effect.ac;
		if (controller !== null) without_reactive_context(() => {
			controller.abort(STALE_REACTION);
		});
		var next = effect.next;
		if ((effect.f & 64) !== 0) effect.parent = null;
		else destroy_effect(effect, remove_dom);
		effect = next;
	}
}
/**
* @param {Effect} signal
* @returns {void}
*/
function destroy_block_effect_children(signal) {
	var effect = signal.first;
	while (effect !== null) {
		var next = effect.next;
		if ((effect.f & 32) === 0) destroy_effect(effect);
		effect = next;
	}
}
/**
* @param {Effect} effect
* @param {boolean} [remove_dom]
* @returns {void}
*/
function destroy_effect(effect, remove_dom = true) {
	var removed = false;
	if ((remove_dom || (effect.f & 262144) !== 0) && effect.nodes !== null && effect.nodes.end !== null) {
		remove_effect_dom(effect.nodes.start, effect.nodes.end);
		removed = true;
	}
	set_signal_status(effect, DESTROYING);
	destroy_effect_children(effect, remove_dom && !removed);
	remove_reactions(effect, 0);
	var transitions = effect.nodes && effect.nodes.t;
	if (transitions !== null) for (const transition of transitions) transition.stop();
	execute_effect_teardown(effect);
	effect.f ^= DESTROYING;
	effect.f |= DESTROYED;
	var parent = effect.parent;
	if (parent !== null && parent.first !== null) unlink_effect(effect);
	effect.next = effect.prev = effect.teardown = effect.ctx = effect.deps = effect.fn = effect.nodes = effect.ac = effect.b = null;
}
/**
*
* @param {TemplateNode | null} node
* @param {TemplateNode} end
*/
function remove_effect_dom(node, end) {
	while (node !== null) {
		/** @type {TemplateNode | null} */
		var next = node === end ? null : /* @__PURE__ */ get_next_sibling(node);
		node.remove();
		node = next;
	}
}
/**
* Detach an effect from the effect tree, freeing up memory and
* reducing the amount of work that happens on subsequent traversals
* @param {Effect} effect
*/
function unlink_effect(effect) {
	var parent = effect.parent;
	var prev = effect.prev;
	var next = effect.next;
	if (prev !== null) prev.next = next;
	if (next !== null) next.prev = prev;
	if (parent !== null) {
		if (parent.first === effect) parent.first = next;
		if (parent.last === effect) parent.last = prev;
	}
}
/**
* When a block effect is removed, we don't immediately destroy it or yank it
* out of the DOM, because it might have transitions. Instead, we 'pause' it.
* It stays around (in memory, and in the DOM) until outro transitions have
* completed, and if the state change is reversed then we _resume_ it.
* A paused effect does not update, and the DOM subtree becomes inert.
* @param {Effect} effect
* @param {() => void} [callback]
* @param {boolean} [destroy]
*/
function pause_effect(effect, callback, destroy = true) {
	/** @type {TransitionManager[]} */
	var transitions = [];
	pause_children(effect, transitions, true);
	var fn = () => {
		if (destroy) destroy_effect(effect);
		if (callback) callback();
	};
	var remaining = transitions.length;
	if (remaining > 0) {
		var check = () => --remaining || fn();
		for (var transition of transitions) transition.out(check);
	} else fn();
}
/**
* @param {Effect} effect
* @param {TransitionManager[]} transitions
* @param {boolean} local
*/
function pause_children(effect, transitions, local) {
	if ((effect.f & 8192) !== 0) return;
	effect.f ^= INERT;
	var t = effect.nodes && effect.nodes.t;
	if (t !== null) {
		for (const transition of t) if (transition.is_global || local) transitions.push(transition);
	}
	var child = effect.first;
	while (child !== null) {
		var sibling = child.next;
		if ((child.f & 64) === 0) {
			var transparent = (child.f & 65536) !== 0 || (child.f & 32) !== 0 && (effect.f & 16) !== 0;
			pause_children(child, transitions, transparent ? local : false);
		}
		child = sibling;
	}
}
/**
* The opposite of `pause_effect`. We call this if (for example)
* `x` becomes falsy then truthy: `{#if x}...{/if}`
* @param {Effect} effect
*/
function resume_effect(effect) {
	resume_children(effect, true);
}
/**
* @param {Effect} effect
* @param {boolean} local
*/
function resume_children(effect, local) {
	if ((effect.f & 8192) === 0) return;
	effect.f ^= INERT;
	if ((effect.f & 1024) === 0) {
		set_signal_status(effect, DIRTY);
		Batch.ensure().schedule(effect);
	}
	var child = effect.first;
	while (child !== null) {
		var sibling = child.next;
		var transparent = (child.f & 65536) !== 0 || (child.f & 32) !== 0;
		resume_children(child, transparent ? local : false);
		child = sibling;
	}
	var t = effect.nodes && effect.nodes.t;
	if (t !== null) {
		for (const transition of t) if (transition.is_global || local) transition.in();
	}
}
/**
* @param {Effect} effect
* @param {DocumentFragment} fragment
*/
function move_effect(effect, fragment) {
	if (!effect.nodes) return;
	/** @type {TemplateNode | null} */
	var node = effect.nodes.start;
	var end = effect.nodes.end;
	while (node !== null) {
		/** @type {TemplateNode | null} */
		var next = node === end ? null : /* @__PURE__ */ get_next_sibling(node);
		fragment.append(node);
		node = next;
	}
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/legacy.js
/**
* @type {Set<Value> | null}
* @deprecated
*/
var captured_signals = null;
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/runtime.js
/** @import { Derived, Effect, Reaction, Source, Value } from '#client' */
var is_updating_effect = false;
var is_destroying_effect = false;
/** @param {boolean} value */
function set_is_destroying_effect(value) {
	is_destroying_effect = value;
}
/** @type {null | Reaction} */
var active_reaction = null;
var untracking = false;
/** @param {null | Reaction} reaction */
function set_active_reaction(reaction) {
	active_reaction = reaction;
}
/** @type {null | Effect} */
var active_effect = null;
/** @param {null | Effect} effect */
function set_active_effect(effect) {
	active_effect = effect;
}
/**
* When sources are created within a reaction, reading and writing
* them within that reaction should not cause a re-run
* @type {null | Source[]}
*/
var current_sources = null;
/** @param {Value} value */
function push_reaction_value(value) {
	if (active_reaction !== null && (!async_mode_flag || (active_reaction.f & 2) !== 0)) if (current_sources === null) current_sources = [value];
	else current_sources.push(value);
}
/**
* The dependencies of the reaction that is currently being executed. In many cases,
* the dependencies are unchanged between runs, and so this will be `null` unless
* and until a new dependency is accessed — we track this via `skipped_deps`
* @type {null | Value[]}
*/
var new_deps = null;
var skipped_deps = 0;
/**
* Tracks writes that the effect it's executed in doesn't listen to yet,
* so that the dependency can be added to the effect later on if it then reads it
* @type {null | Source[]}
*/
var untracked_writes = null;
/** @param {null | Source[]} value */
function set_untracked_writes(value) {
	untracked_writes = value;
}
/**
* @type {number} Used by sources and deriveds for handling updates.
* Version starts from 1 so that unowned deriveds differentiate between a created effect and a run one for tracing
**/
var write_version = 1;
/** @type {number} Used to version each read of a source of derived to avoid duplicating depedencies inside a reaction */
var read_version = 0;
var update_version = read_version;
/** @param {number} value */
function set_update_version(value) {
	update_version = value;
}
function increment_write_version() {
	return ++write_version;
}
/**
* Determines whether a derived or effect is dirty.
* If it is MAYBE_DIRTY, will set the status to CLEAN
* @param {Reaction} reaction
* @returns {boolean}
*/
function is_dirty(reaction) {
	var flags = reaction.f;
	if ((flags & 2048) !== 0) return true;
	if (flags & 2) reaction.f &= ~WAS_MARKED;
	if ((flags & 4096) !== 0) {
		var dependencies = reaction.deps;
		var length = dependencies.length;
		for (var i = 0; i < length; i++) {
			var dependency = dependencies[i];
			if (is_dirty(dependency)) update_derived(dependency);
			if (dependency.wv > reaction.wv) return true;
		}
		if ((flags & 512) !== 0 && batch_values === null) set_signal_status(reaction, CLEAN);
	}
	return false;
}
/**
* @param {Value} signal
* @param {Effect} effect
* @param {boolean} [root]
*/
function schedule_possible_effect_self_invalidation(signal, effect, root = true) {
	var reactions = signal.reactions;
	if (reactions === null) return;
	if (!async_mode_flag && current_sources !== null && includes.call(current_sources, signal)) return;
	for (var i = 0; i < reactions.length; i++) {
		var reaction = reactions[i];
		if ((reaction.f & 2) !== 0) schedule_possible_effect_self_invalidation(reaction, effect, false);
		else if (effect === reaction) {
			if (root) set_signal_status(reaction, DIRTY);
			else if ((reaction.f & 1024) !== 0) set_signal_status(reaction, MAYBE_DIRTY);
			schedule_effect(reaction);
		}
	}
}
/** @param {Reaction} reaction */
function update_reaction(reaction) {
	var previous_deps = new_deps;
	var previous_skipped_deps = skipped_deps;
	var previous_untracked_writes = untracked_writes;
	var previous_reaction = active_reaction;
	var previous_sources = current_sources;
	var previous_component_context = component_context;
	var previous_untracking = untracking;
	var previous_update_version = update_version;
	var flags = reaction.f;
	new_deps = null;
	skipped_deps = 0;
	untracked_writes = null;
	active_reaction = (flags & 96) === 0 ? reaction : null;
	current_sources = null;
	set_component_context(reaction.ctx);
	untracking = false;
	update_version = ++read_version;
	if (reaction.ac !== null) {
		without_reactive_context(() => {
			/** @type {AbortController} */ reaction.ac.abort(STALE_REACTION);
		});
		reaction.ac = null;
	}
	try {
		reaction.f |= REACTION_IS_UPDATING;
		var fn = reaction.fn;
		var result = fn();
		reaction.f |= REACTION_RAN;
		var deps = reaction.deps;
		var is_fork = current_batch?.is_fork;
		if (new_deps !== null) {
			var i;
			if (!is_fork) remove_reactions(reaction, skipped_deps);
			if (deps !== null && skipped_deps > 0) {
				deps.length = skipped_deps + new_deps.length;
				for (i = 0; i < new_deps.length; i++) deps[skipped_deps + i] = new_deps[i];
			} else reaction.deps = deps = new_deps;
			if (effect_tracking() && (reaction.f & 512) !== 0) for (i = skipped_deps; i < deps.length; i++) (deps[i].reactions ??= []).push(reaction);
		} else if (!is_fork && deps !== null && skipped_deps < deps.length) {
			remove_reactions(reaction, skipped_deps);
			deps.length = skipped_deps;
		}
		if (is_runes() && untracked_writes !== null && !untracking && deps !== null && (reaction.f & 6146) === 0) for (i = 0; i < untracked_writes.length; i++) schedule_possible_effect_self_invalidation(untracked_writes[i], reaction);
		if (previous_reaction !== null && previous_reaction !== reaction) {
			read_version++;
			if (previous_reaction.deps !== null) for (let i = 0; i < previous_skipped_deps; i += 1) previous_reaction.deps[i].rv = read_version;
			if (previous_deps !== null) for (const dep of previous_deps) dep.rv = read_version;
			if (untracked_writes !== null) if (previous_untracked_writes === null) previous_untracked_writes = untracked_writes;
			else previous_untracked_writes.push(...untracked_writes);
		}
		if ((reaction.f & 8388608) !== 0) reaction.f ^= ERROR_VALUE;
		return result;
	} catch (error) {
		return handle_error(error);
	} finally {
		reaction.f ^= REACTION_IS_UPDATING;
		new_deps = previous_deps;
		skipped_deps = previous_skipped_deps;
		untracked_writes = previous_untracked_writes;
		active_reaction = previous_reaction;
		current_sources = previous_sources;
		set_component_context(previous_component_context);
		untracking = previous_untracking;
		update_version = previous_update_version;
	}
}
/**
* @template V
* @param {Reaction} signal
* @param {Value<V>} dependency
* @returns {void}
*/
function remove_reaction(signal, dependency) {
	let reactions = dependency.reactions;
	if (reactions !== null) {
		var index = index_of.call(reactions, signal);
		if (index !== -1) {
			var new_length = reactions.length - 1;
			if (new_length === 0) reactions = dependency.reactions = null;
			else {
				reactions[index] = reactions[new_length];
				reactions.pop();
			}
		}
	}
	if (reactions === null && (dependency.f & 2) !== 0 && (new_deps === null || !includes.call(new_deps, dependency))) {
		var derived = dependency;
		if ((derived.f & 512) !== 0) {
			derived.f ^= 512;
			derived.f &= ~WAS_MARKED;
		}
		if (derived.v !== UNINITIALIZED) update_derived_status(derived);
		freeze_derived_effects(derived);
		remove_reactions(derived, 0);
	}
}
/**
* @param {Reaction} signal
* @param {number} start_index
* @returns {void}
*/
function remove_reactions(signal, start_index) {
	var dependencies = signal.deps;
	if (dependencies === null) return;
	for (var i = start_index; i < dependencies.length; i++) remove_reaction(signal, dependencies[i]);
}
/**
* @param {Effect} effect
* @returns {void}
*/
function update_effect(effect) {
	var flags = effect.f;
	if ((flags & 16384) !== 0) return;
	set_signal_status(effect, CLEAN);
	var previous_effect = active_effect;
	var was_updating_effect = is_updating_effect;
	active_effect = effect;
	is_updating_effect = true;
	try {
		if ((flags & 16777232) !== 0) destroy_block_effect_children(effect);
		else destroy_effect_children(effect);
		execute_effect_teardown(effect);
		var teardown = update_reaction(effect);
		effect.teardown = typeof teardown === "function" ? teardown : null;
		effect.wv = write_version;
	} finally {
		is_updating_effect = was_updating_effect;
		active_effect = previous_effect;
	}
}
/**
* Returns a promise that resolves once any pending state changes have been applied.
* @returns {Promise<void>}
*/
async function tick() {
	if (async_mode_flag) return new Promise((f) => {
		requestAnimationFrame(() => f());
		setTimeout(() => f());
	});
	await Promise.resolve();
	flushSync();
}
/**
* @template V
* @param {Value<V>} signal
* @returns {V}
*/
function get(signal) {
	var is_derived = (signal.f & 2) !== 0;
	captured_signals?.add(signal);
	if (active_reaction !== null && !untracking) {
		if (!(active_effect !== null && (active_effect.f & 16384) !== 0) && (current_sources === null || !includes.call(current_sources, signal))) {
			var deps = active_reaction.deps;
			if ((active_reaction.f & 2097152) !== 0) {
				if (signal.rv < read_version) {
					signal.rv = read_version;
					if (new_deps === null && deps !== null && deps[skipped_deps] === signal) skipped_deps++;
					else if (new_deps === null) new_deps = [signal];
					else new_deps.push(signal);
				}
			} else {
				(active_reaction.deps ??= []).push(signal);
				var reactions = signal.reactions;
				if (reactions === null) signal.reactions = [active_reaction];
				else if (!includes.call(reactions, active_reaction)) reactions.push(active_reaction);
			}
		}
	}
	if (is_destroying_effect && old_values.has(signal)) return old_values.get(signal);
	if (is_derived) {
		var derived = signal;
		if (is_destroying_effect) {
			var value = derived.v;
			if ((derived.f & 1024) === 0 && derived.reactions !== null || depends_on_old_values(derived)) value = execute_derived(derived);
			old_values.set(derived, value);
			return value;
		}
		var should_connect = (derived.f & 512) === 0 && !untracking && active_reaction !== null && (is_updating_effect || (active_reaction.f & 512) !== 0);
		var is_new = (derived.f & REACTION_RAN) === 0;
		if (is_dirty(derived)) {
			if (should_connect) derived.f |= 512;
			update_derived(derived);
		}
		if (should_connect && !is_new) {
			unfreeze_derived_effects(derived);
			reconnect(derived);
		}
	}
	if (batch_values?.has(signal)) return batch_values.get(signal);
	if ((signal.f & 8388608) !== 0) throw signal.v;
	return signal.v;
}
/**
* (Re)connect a disconnected derived, so that it is notified
* of changes in `mark_reactions`
* @param {Derived} derived
*/
function reconnect(derived) {
	derived.f |= 512;
	if (derived.deps === null) return;
	for (const dep of derived.deps) {
		(dep.reactions ??= []).push(derived);
		if ((dep.f & 2) !== 0 && (dep.f & 512) === 0) {
			unfreeze_derived_effects(dep);
			reconnect(dep);
		}
	}
}
/** @param {Derived} derived */
function depends_on_old_values(derived) {
	if (derived.v === UNINITIALIZED) return true;
	if (derived.deps === null) return false;
	for (const dep of derived.deps) {
		if (old_values.has(dep)) return true;
		if ((dep.f & 2) !== 0 && depends_on_old_values(dep)) return true;
	}
	return false;
}
/**
* When used inside a [`$derived`](https://svelte.dev/docs/svelte/$derived) or [`$effect`](https://svelte.dev/docs/svelte/$effect),
* any state read inside `fn` will not be treated as a dependency.
*
* ```ts
* $effect(() => {
*   // this will run when `data` changes, but not when `time` changes
*   save(data, {
*     timestamp: untrack(() => time)
*   });
* });
* ```
* @template T
* @param {() => T} fn
* @returns {T}
*/
function untrack(fn) {
	var previous_untracking = untracking;
	try {
		untracking = true;
		return fn();
	} finally {
		untracking = previous_untracking;
	}
}
/**
* Possibly traverse an object and read all its properties so that they're all reactive in case this is `$state`.
* Does only check first level of an object for performance reasons (heuristic should be good for 99% of all cases).
* @param {any} value
* @returns {void}
*/
function deep_read_state(value) {
	if (typeof value !== "object" || !value || value instanceof EventTarget) return;
	if (STATE_SYMBOL in value) deep_read(value);
	else if (!Array.isArray(value)) for (let key in value) {
		const prop = value[key];
		if (typeof prop === "object" && prop && STATE_SYMBOL in prop) deep_read(prop);
	}
}
/**
* Deeply traverse an object and read all its properties
* so that they're all reactive in case this is `$state`
* @param {any} value
* @param {Set<any>} visited
* @returns {void}
*/
function deep_read(value, visited = /* @__PURE__ */ new Set()) {
	if (typeof value === "object" && value !== null && !(value instanceof EventTarget) && !visited.has(value)) {
		visited.add(value);
		if (value instanceof Date) value.getTime();
		for (let key in value) try {
			deep_read(value[key], visited);
		} catch (e) {}
		const proto = get_prototype_of(value);
		if (proto !== Object.prototype && proto !== Array.prototype && proto !== Map.prototype && proto !== Set.prototype && proto !== Date.prototype) {
			const descriptors = get_descriptors(proto);
			for (let key in descriptors) {
				const get = descriptors[key].get;
				if (get) try {
					get.call(value);
				} catch (e) {}
			}
		}
	}
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/events.js
/**
* Used on elements, as a map of event type -> event handler,
* and on events themselves to track which element handled an event
*/
var event_symbol = Symbol("events");
/** @type {Set<string>} */
var all_registered_events = /* @__PURE__ */ new Set();
/** @type {Set<(events: Array<string>) => void>} */
var root_event_handles = /* @__PURE__ */ new Set();
/**
* SSR adds onload and onerror attributes to catch those events before the hydration.
* This function detects those cases, removes the attributes and replays the events.
* @param {HTMLElement} dom
*/
function replay_events(dom) {
	if (!hydrating) return;
	dom.removeAttribute("onload");
	dom.removeAttribute("onerror");
	const event = dom.__e;
	if (event !== void 0) {
		dom.__e = void 0;
		queueMicrotask(() => {
			if (dom.isConnected) dom.dispatchEvent(event);
		});
	}
}
/**
* @param {string} event_name
* @param {EventTarget} dom
* @param {EventListener} [handler]
* @param {AddEventListenerOptions} [options]
*/
function create_event(event_name, dom, handler, options = {}) {
	/**
	* @this {EventTarget}
	*/
	function target_handler(event) {
		if (!options.capture) handle_event_propagation.call(dom, event);
		if (!event.cancelBubble) return without_reactive_context(() => {
			return handler?.call(this, event);
		});
	}
	if (event_name.startsWith("pointer") || event_name.startsWith("touch") || event_name === "wheel") queue_micro_task(() => {
		dom.addEventListener(event_name, target_handler, options);
	});
	else dom.addEventListener(event_name, target_handler, options);
	return target_handler;
}
/**
* Attaches an event handler to an element and returns a function that removes the handler. Using this
* rather than `addEventListener` will preserve the correct order relative to handlers added declaratively
* (with attributes like `onclick`), which use event delegation for performance reasons
*
* @param {EventTarget} element
* @param {string} type
* @param {EventListener} handler
* @param {AddEventListenerOptions} [options]
*/
function on(element, type, handler, options = {}) {
	var target_handler = create_event(type, element, handler, options);
	return () => {
		element.removeEventListener(type, target_handler, options);
	};
}
/**
* @param {string} event_name
* @param {Element} dom
* @param {EventListener} [handler]
* @param {boolean} [capture]
* @param {boolean} [passive]
* @returns {void}
*/
function event(event_name, dom, handler, capture, passive) {
	var options = {
		capture,
		passive
	};
	var target_handler = create_event(event_name, dom, handler, options);
	if (dom === document.body || dom === window || dom === document || dom instanceof HTMLMediaElement) teardown(() => {
		dom.removeEventListener(event_name, target_handler, options);
	});
}
/**
* @param {string} event_name
* @param {Element} element
* @param {EventListener} [handler]
* @returns {void}
*/
function delegated(event_name, element, handler) {
	(element[event_symbol] ??= {})[event_name] = handler;
}
/**
* @param {Array<string>} events
* @returns {void}
*/
function delegate(events) {
	for (var i = 0; i < events.length; i++) all_registered_events.add(events[i]);
	for (var fn of root_event_handles) fn(events);
}
var last_propagated_event = null;
/**
* @this {EventTarget}
* @param {Event} event
* @returns {void}
*/
function handle_event_propagation(event) {
	var handler_element = this;
	var owner_document = handler_element.ownerDocument;
	var event_name = event.type;
	var path = event.composedPath?.() || [];
	var current_target = path[0] || event.target;
	last_propagated_event = event;
	var path_idx = 0;
	var handled_at = last_propagated_event === event && event[event_symbol];
	if (handled_at) {
		var at_idx = path.indexOf(handled_at);
		if (at_idx !== -1 && (handler_element === document || handler_element === window)) {
			event[event_symbol] = handler_element;
			return;
		}
		var handler_idx = path.indexOf(handler_element);
		if (handler_idx === -1) return;
		if (at_idx <= handler_idx) path_idx = at_idx;
	}
	current_target = path[path_idx] || event.target;
	if (current_target === handler_element) return;
	define_property(event, "currentTarget", {
		configurable: true,
		get() {
			return current_target || owner_document;
		}
	});
	var previous_reaction = active_reaction;
	var previous_effect = active_effect;
	set_active_reaction(null);
	set_active_effect(null);
	try {
		/**
		* @type {unknown}
		*/
		var throw_error;
		/**
		* @type {unknown[]}
		*/
		var other_errors = [];
		while (current_target !== null) {
			/** @type {null | Element} */
			var parent_element = current_target.assignedSlot || current_target.parentNode || current_target.host || null;
			try {
				var delegated = current_target[event_symbol]?.[event_name];
				if (delegated != null && (!current_target.disabled || event.target === current_target)) delegated.call(current_target, event);
			} catch (error) {
				if (throw_error) other_errors.push(error);
				else throw_error = error;
			}
			if (event.cancelBubble || parent_element === handler_element || parent_element === null) break;
			current_target = parent_element;
		}
		if (throw_error) {
			for (let error of other_errors) queueMicrotask(() => {
				throw error;
			});
			throw throw_error;
		}
	} finally {
		event[event_symbol] = handler_element;
		delete event.currentTarget;
		set_active_reaction(previous_reaction);
		set_active_effect(previous_effect);
	}
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/reconciler.js
var policy = globalThis?.window?.trustedTypes && /* @__PURE__ */ globalThis.window.trustedTypes.createPolicy("svelte-trusted-html", { 
/** @param {string} html */
createHTML: (html) => {
	return html;
} });
/** @param {string} html */
function create_trusted_html(html) {
	return policy?.createHTML(html) ?? html;
}
/**
* @param {string} html
*/
function create_fragment_from_html(html) {
	var elem = create_element("template");
	elem.innerHTML = create_trusted_html(html.replaceAll("<!>", "<!---->"));
	return elem.content;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/template.js
/** @import { Effect, EffectNodes, TemplateNode } from '#client' */
/** @import { TemplateStructure } from './types' */
/**
* @param {TemplateNode} start
* @param {TemplateNode | null} end
*/
function assign_nodes(start, end) {
	var effect = active_effect;
	if (effect.nodes === null) effect.nodes = {
		start,
		end,
		a: null,
		t: null
	};
}
/**
* @param {string} content
* @param {number} flags
* @returns {() => Node | Node[]}
*/
/* @__NO_SIDE_EFFECTS__ */
function from_html(content, flags) {
	var is_fragment = (flags & 1) !== 0;
	var use_import_node = (flags & 2) !== 0;
	/** @type {Node} */
	var node;
	/**
	* Whether or not the first item is a text/element node. If not, we need to
	* create an additional comment node to act as `effect.nodes.start`
	*/
	var has_start = !content.startsWith("<!>");
	return () => {
		if (hydrating) {
			assign_nodes(hydrate_node, null);
			return hydrate_node;
		}
		if (node === void 0) {
			node = create_fragment_from_html(has_start ? content : "<!>" + content);
			if (!is_fragment) node = /* @__PURE__ */ get_first_child(node);
		}
		var clone = use_import_node || is_firefox ? document.importNode(node, true) : node.cloneNode(true);
		if (is_fragment) {
			var start = /* @__PURE__ */ get_first_child(clone);
			var end = clone.lastChild;
			assign_nodes(start, end);
		} else assign_nodes(clone, clone);
		return clone;
	};
}
/**
* @returns {TemplateNode | DocumentFragment}
*/
function comment() {
	if (hydrating) {
		assign_nodes(hydrate_node, null);
		return hydrate_node;
	}
	var frag = document.createDocumentFragment();
	var start = document.createComment("");
	var anchor = create_text();
	frag.append(start, anchor);
	assign_nodes(start, anchor);
	return frag;
}
/**
* Assign the created (or in hydration mode, traversed) dom elements to the current block
* and insert the elements into the dom (in client mode).
* @param {Text | Comment | Element} anchor
* @param {DocumentFragment | Element} dom
*/
function append(anchor, dom) {
	if (hydrating) {
		var effect = active_effect;
		if ((effect.f & 32768) === 0 || effect.nodes.end === null) effect.nodes.end = hydrate_node;
		hydrate_next();
		return;
	}
	if (anchor === null) return;
	anchor.before(dom);
}
/**
* Create (or hydrate) an unique UID for the component instance.
*/
function props_id() {
	if (hydrating && hydrate_node && hydrate_node.nodeType === 8 && hydrate_node.textContent?.startsWith(`$`)) {
		const id = hydrate_node.textContent.substring(1);
		hydrate_next();
		return id;
	}
	(window.__svelte ??= {}).uid ??= 1;
	return `c${window.__svelte.uid++}`;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/utils.js
/**
* @param {string} name
*/
function is_capture_event(name) {
	return name.endsWith("capture") && name !== "gotpointercapture" && name !== "lostpointercapture";
}
/** List of Element events that will be delegated */
var DELEGATED_EVENTS = [
	"beforeinput",
	"click",
	"change",
	"dblclick",
	"contextmenu",
	"focusin",
	"focusout",
	"input",
	"keydown",
	"keyup",
	"mousedown",
	"mousemove",
	"mouseout",
	"mouseover",
	"mouseup",
	"pointerdown",
	"pointermove",
	"pointerout",
	"pointerover",
	"pointerup",
	"touchend",
	"touchmove",
	"touchstart"
];
/**
* Returns `true` if `event_name` is a delegated event
* @param {string} event_name
*/
function can_delegate_event(event_name) {
	return DELEGATED_EVENTS.includes(event_name);
}
/**
* Attributes that are boolean, i.e. they are present or not present.
*/
var DOM_BOOLEAN_ATTRIBUTES = [
	"allowfullscreen",
	"async",
	"autofocus",
	"autoplay",
	"checked",
	"controls",
	"default",
	"disabled",
	"formnovalidate",
	"indeterminate",
	"inert",
	"ismap",
	"loop",
	"multiple",
	"muted",
	"nomodule",
	"novalidate",
	"open",
	"playsinline",
	"readonly",
	"required",
	"reversed",
	"seamless",
	"selected",
	"webkitdirectory",
	"defer",
	"disablepictureinpicture",
	"disableremoteplayback"
];
/**
* @type {Record<string, string>}
* List of attribute names that should be aliased to their property names
* because they behave differently between setting them as an attribute and
* setting them as a property.
*/
var ATTRIBUTE_ALIASES = {
	formnovalidate: "formNoValidate",
	ismap: "isMap",
	nomodule: "noModule",
	playsinline: "playsInline",
	readonly: "readOnly",
	defaultvalue: "defaultValue",
	defaultchecked: "defaultChecked",
	srcobject: "srcObject",
	novalidate: "noValidate",
	allowfullscreen: "allowFullscreen",
	disablepictureinpicture: "disablePictureInPicture",
	disableremoteplayback: "disableRemotePlayback"
};
/**
* @param {string} name
*/
function normalize_attribute(name) {
	name = name.toLowerCase();
	return ATTRIBUTE_ALIASES[name] ?? name;
}
[...DOM_BOOLEAN_ATTRIBUTES];
/**
* Subset of delegated events which should be passive by default.
* These two are already passive via browser defaults on window, document and body.
* But since
* - we're delegating them
* - they happen often
* - they apply to mobile which is generally less performant
* we're marking them as passive by default for other elements, too.
*/
var PASSIVE_EVENTS = ["touchstart", "touchmove"];
/**
* Returns `true` if `name` is a passive event
* @param {string} name
*/
function is_passive_event(name) {
	return PASSIVE_EVENTS.includes(name);
}
/**
* @param {Element} text
* @param {string} value
* @returns {void}
*/
function set_text(text, value) {
	var str = value == null ? "" : typeof value === "object" ? `${value}` : value;
	if (str !== (text[TEXT_CACHE] ??= text.nodeValue)) {
		/** @type {any} */ text[TEXT_CACHE] = str;
		text.nodeValue = `${str}`;
	}
}
/**
* Mounts a component to the given target and returns the exports and potentially the props (if compiled with `accessors: true`) of the component.
* Transitions will play during the initial render unless the `intro` option is set to `false`.
*
* @template {Record<string, any>} Props
* @template {Record<string, any>} Exports
* @param {ComponentType<SvelteComponent<Props>> | Component<Props, Exports, any>} component
* @param {MountOptions<Props>} options
* @returns {Exports}
*/
function mount(component, options) {
	return _mount(component, options);
}
/** @type {Map<EventTarget, Map<string, number>>} */
var listeners = /* @__PURE__ */ new Map();
/**
* @template {Record<string, any>} Exports
* @param {ComponentType<SvelteComponent<any>> | Component<any>} Component
* @param {MountOptions} options
* @returns {Exports}
*/
function _mount(Component, { target, anchor, props = {}, events, context, intro = true, transformError }) {
	init_operations();
	/** @type {Exports} */
	var component = void 0;
	var unmount = component_root(() => {
		var anchor_node = anchor ?? target.appendChild(create_text());
		boundary(anchor_node, { pending: () => {} }, (anchor_node) => {
			push({});
			var ctx = component_context;
			if (context) ctx.c = context;
			if (events)
 /** @type {any} */ props.$$events = events;
			if (hydrating) assign_nodes(anchor_node, null);
			component = Component(anchor_node, props) || {};
			if (hydrating) {
				/** @type {Effect & { nodes: EffectNodes }} */ active_effect.nodes.end = hydrate_node;
				if (hydrate_node === null || hydrate_node.nodeType !== 8 || hydrate_node.data !== "]") {
					hydration_mismatch();
					throw HYDRATION_ERROR;
				}
			}
			pop();
		}, transformError);
		/** @type {Set<string>} */
		var registered_events = /* @__PURE__ */ new Set();
		/** @param {Array<string>} events */
		var event_handle = (events) => {
			for (var i = 0; i < events.length; i++) {
				var event_name = events[i];
				if (registered_events.has(event_name)) continue;
				registered_events.add(event_name);
				var passive = is_passive_event(event_name);
				for (const node of [target, document]) {
					var counts = listeners.get(node);
					if (counts === void 0) {
						counts = /* @__PURE__ */ new Map();
						listeners.set(node, counts);
					}
					var count = counts.get(event_name);
					if (count === void 0) {
						node.addEventListener(event_name, handle_event_propagation, { passive });
						counts.set(event_name, 1);
					} else counts.set(event_name, count + 1);
				}
			}
		};
		event_handle(array_from(all_registered_events));
		root_event_handles.add(event_handle);
		return () => {
			for (var event_name of registered_events) for (const node of [target, document]) {
				var counts = listeners.get(node);
				var count = counts.get(event_name);
				if (--count == 0) {
					node.removeEventListener(event_name, handle_event_propagation);
					counts.delete(event_name);
					if (counts.size === 0) listeners.delete(node);
				} else counts.set(event_name, count);
			}
			root_event_handles.delete(event_handle);
			if (anchor_node !== anchor) anchor_node.parentNode?.removeChild(anchor_node);
		};
	});
	mounted_components.set(component, unmount);
	return component;
}
/**
* References of the components that were mounted or hydrated.
* Uses a `WeakMap` to avoid memory leaks.
*/
var mounted_components = /* @__PURE__ */ new WeakMap();
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/blocks/branches.js
/** @import { Effect, TemplateNode } from '#client' */
/**
* @typedef {{ effect: Effect, fragment: DocumentFragment }} Branch
*/
/**
* @template Key
*/
var BranchManager = class {
	/** @type {TemplateNode} */
	anchor;
	/** @type {Map<Batch, Key>} */
	#batches = /* @__PURE__ */ new Map();
	/**
	* Map of keys to effects that are currently rendered in the DOM.
	* These effects are visible and actively part of the document tree.
	* Example:
	* ```
	* {#if condition}
	* 	foo
	* {:else}
	* 	bar
	* {/if}
	* ```
	* Can result in the entries `true->Effect` and `false->Effect`
	* @type {Map<Key, Effect>}
	*/
	#onscreen = /* @__PURE__ */ new Map();
	/**
	* Similar to #onscreen with respect to the keys, but contains branches that are not yet
	* in the DOM, because their insertion is deferred.
	* @type {Map<Key, Branch>}
	*/
	#offscreen = /* @__PURE__ */ new Map();
	/**
	* Keys of effects that are currently outroing
	* @type {Set<Key>}
	*/
	#outroing = /* @__PURE__ */ new Set();
	/**
	* Whether to pause (i.e. outro) on change, or destroy immediately.
	* This is necessary for `<svelte:element>`
	*/
	#transition = true;
	/**
	* @param {TemplateNode} anchor
	* @param {boolean} transition
	*/
	constructor(anchor, transition = true) {
		this.anchor = anchor;
		this.#transition = transition;
	}
	/**
	* @param {Batch} batch
	*/
	#commit = (batch) => {
		if (!this.#batches.has(batch)) return;
		var key = this.#batches.get(batch);
		var onscreen = this.#onscreen.get(key);
		if (onscreen) {
			resume_effect(onscreen);
			this.#outroing.delete(key);
		} else {
			var offscreen = this.#offscreen.get(key);
			if (offscreen) {
				this.#onscreen.set(key, offscreen.effect);
				this.#offscreen.delete(key);
				/** @type {TemplateNode} */ offscreen.fragment.lastChild.remove();
				this.anchor.before(offscreen.fragment);
				onscreen = offscreen.effect;
			}
		}
		for (const [b, k] of this.#batches) {
			this.#batches.delete(b);
			if (b === batch) break;
			const offscreen = this.#offscreen.get(k);
			if (offscreen) {
				destroy_effect(offscreen.effect);
				this.#offscreen.delete(k);
			}
		}
		for (const [k, effect] of this.#onscreen) {
			if (k === key || this.#outroing.has(k)) continue;
			const on_destroy = () => {
				if (Array.from(this.#batches.values()).includes(k)) {
					var fragment = document.createDocumentFragment();
					move_effect(effect, fragment);
					fragment.append(create_text());
					this.#offscreen.set(k, {
						effect,
						fragment
					});
				} else destroy_effect(effect);
				this.#outroing.delete(k);
				this.#onscreen.delete(k);
			};
			if (this.#transition || !onscreen) {
				this.#outroing.add(k);
				pause_effect(effect, on_destroy, false);
			} else on_destroy();
		}
	};
	/**
	* @param {Batch} batch
	*/
	#discard = (batch) => {
		this.#batches.delete(batch);
		const keys = Array.from(this.#batches.values());
		for (const [k, branch] of this.#offscreen) if (!keys.includes(k)) {
			destroy_effect(branch.effect);
			this.#offscreen.delete(k);
		}
	};
	/**
	*
	* @param {any} key
	* @param {null | ((target: TemplateNode) => void)} fn
	*/
	ensure(key, fn) {
		var batch = current_batch;
		var defer = should_defer_append();
		if (fn && !this.#onscreen.has(key) && !this.#offscreen.has(key)) if (defer) {
			var fragment = document.createDocumentFragment();
			var target = create_text();
			fragment.append(target);
			this.#offscreen.set(key, {
				effect: branch(() => fn(target)),
				fragment
			});
		} else this.#onscreen.set(key, branch(() => fn(this.anchor)));
		this.#batches.set(batch, key);
		if (defer) {
			for (const [k, effect] of this.#onscreen) if (k === key) batch.unskip_effect(effect);
			else batch.skip_effect(effect);
			for (const [k, branch] of this.#offscreen) if (k === key) batch.unskip_effect(branch.effect);
			else batch.skip_effect(branch.effect);
			batch.oncommit(this.#commit);
			batch.ondiscard(this.#discard);
		} else {
			if (hydrating) this.anchor = hydrate_node;
			this.#commit(batch);
		}
	}
};
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/blocks/snippet.js
/** @import { Snippet } from 'svelte' */
/** @import { TemplateNode } from '#client' */
/** @import { Getters } from '#shared' */
/**
* @template {(node: TemplateNode, ...args: any[]) => void} SnippetFn
* @param {TemplateNode} node
* @param {() => SnippetFn | null | undefined} get_snippet
* @param {(() => any)[]} args
* @returns {void}
*/
function snippet(node, get_snippet, ...args) {
	var branches = new BranchManager(node);
	block(() => {
		const snippet = get_snippet() ?? null;
		branches.ensure(snippet, snippet && ((anchor) => snippet(anchor, ...args)));
	}, EFFECT_TRANSPARENT);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/attachments/index.js
/**
* Creates an object key that will be recognised as an attachment when the object is spread onto an element,
* as a programmatic alternative to using `{@attach ...}`. This can be useful for library authors, though
* is generally not needed when building an app.
*
* ```svelte
* <script>
* 	import { createAttachmentKey } from 'svelte/attachments';
*
* 	const props = {
* 		class: 'cool',
* 		onclick: () => alert('clicked'),
* 		[createAttachmentKey()]: (node) => {
* 			node.textContent = 'attached!';
* 		}
* 	};
* <\/script>
*
* <button {...props}>click me</button>
* ```
* @since 5.29
*/
function createAttachmentKey() {
	return Symbol(ATTACHMENT_KEY);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/blocks/if.js
/** @import { TemplateNode } from '#client' */
/**
* @param {TemplateNode} node
* @param {(branch: (fn: (anchor: Node) => void, key?: number | false) => void) => void} fn
* @param {boolean} [elseif] True if this is an `{:else if ...}` block rather than an `{#if ...}`, as that affects which transitions are considered 'local'
* @returns {void}
*/
function if_block(node, fn, elseif = false) {
	/** @type {TemplateNode | undefined} */
	var marker;
	if (hydrating) {
		marker = hydrate_node;
		hydrate_next();
	}
	var branches = new BranchManager(node);
	var flags = elseif ? EFFECT_TRANSPARENT : 0;
	/**
	* @param {number | false} key
	* @param {null | ((anchor: Node) => void)} fn
	*/
	function update_branch(key, fn) {
		if (hydrating) {
			var data = read_hydration_instruction(marker);
			if (key !== parseInt(data.substring(1))) {
				var anchor = skip_nodes();
				set_hydrate_node(anchor);
				branches.anchor = anchor;
				set_hydrating(false);
				branches.ensure(key, fn);
				set_hydrating(true);
				return;
			}
		}
		branches.ensure(key, fn);
	}
	block(() => {
		var has_branch = false;
		fn((fn, key = 0) => {
			has_branch = true;
			update_branch(key, fn);
		});
		if (!has_branch) update_branch(-1, null);
	}, flags);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/attachments.js
/** @import { Effect } from '#client' */
/**
* @param {Element} node
* @param {() => (node: Element) => void} get_fn
*/
function attach(node, get_fn) {
	/** @type {false | undefined | ((node: Element) => void)} */
	var fn = void 0;
	/** @type {Effect | null} */
	var e;
	managed(() => {
		if (fn !== (fn = get_fn())) {
			if (e) {
				destroy_effect(e);
				e = null;
			}
			if (fn) e = branch(() => {
				effect(() => fn(node));
			});
		}
	});
}
//#endregion
//#region node_modules/.pnpm/clsx@2.1.1/node_modules/clsx/dist/clsx.mjs
function r(e) {
	var t, f, n = "";
	if ("string" == typeof e || "number" == typeof e) n += e;
	else if ("object" == typeof e) if (Array.isArray(e)) {
		var o = e.length;
		for (t = 0; t < o; t++) e[t] && (f = r(e[t])) && (n && (n += " "), n += f);
	} else for (f in e) e[f] && (n && (n += " "), n += f);
	return n;
}
function clsx$1() {
	for (var e, t, f = 0, n = "", o = arguments.length; f < o; f++) (e = arguments[f]) && (t = r(e)) && (n && (n += " "), n += t);
	return n;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/shared/attributes.js
/**
* Small wrapper around clsx to preserve Svelte's (weird) handling of falsy values.
* TODO Svelte 6 revisit this, and likely turn all falsy values into the empty string (what clsx also does)
* @param  {any} value
*/
function clsx(value) {
	if (typeof value === "object") return clsx$1(value);
	else return value ?? "";
}
var whitespace = [..." 	\n\r\f\xA0\v﻿"];
/**
* @param {any} value
* @param {string | null} [hash]
* @param {Record<string, boolean>} [directives]
* @returns {string | null}
*/
function to_class(value, hash, directives) {
	var classname = value == null ? "" : "" + value;
	if (hash) classname = classname ? classname + " " + hash : hash;
	if (directives) {
		for (var key of Object.keys(directives)) if (directives[key]) classname = classname ? classname + " " + key : key;
		else if (classname.length) {
			var len = key.length;
			var a = 0;
			while ((a = classname.indexOf(key, a)) >= 0) {
				var b = a + len;
				if ((a === 0 || whitespace.includes(classname[a - 1])) && (b === classname.length || whitespace.includes(classname[b]))) classname = (a === 0 ? "" : classname.substring(0, a)) + classname.substring(b + 1);
				else a = b;
			}
		}
	}
	return classname === "" ? null : classname;
}
/**
*
* @param {Record<string,any>} styles
* @param {boolean} important
*/
function append_styles(styles, important = false) {
	var separator = important ? " !important;" : ";";
	var css = "";
	for (var key of Object.keys(styles)) {
		var value = styles[key];
		if (value != null && value !== "") css += " " + key + ": " + value + separator;
	}
	return css;
}
/**
* @param {string} name
* @returns {string}
*/
function to_css_name(name) {
	if (name[0] !== "-" || name[1] !== "-") return name.toLowerCase();
	return name;
}
/**
* @param {any} value
* @param {Record<string, any> | [Record<string, any>, Record<string, any>]} [styles]
* @returns {string | null}
*/
function to_style(value, styles) {
	if (styles) {
		var new_style = "";
		/** @type {Record<string,any> | undefined} */
		var normal_styles;
		/** @type {Record<string,any> | undefined} */
		var important_styles;
		if (Array.isArray(styles)) {
			normal_styles = styles[0];
			important_styles = styles[1];
		} else normal_styles = styles;
		if (value) {
			value = String(value).replaceAll(/\s*\/\*.*?\*\/\s*/g, "").trim();
			/** @type {boolean | '"' | "'"} */
			var in_str = false;
			var in_apo = 0;
			var in_comment = false;
			var reserved_names = [];
			if (normal_styles) reserved_names.push(...Object.keys(normal_styles).map(to_css_name));
			if (important_styles) reserved_names.push(...Object.keys(important_styles).map(to_css_name));
			var start_index = 0;
			var name_index = -1;
			const len = value.length;
			for (var i = 0; i < len; i++) {
				var c = value[i];
				if (in_comment) {
					if (c === "/" && value[i - 1] === "*") in_comment = false;
				} else if (in_str) {
					if (in_str === c) in_str = false;
				} else if (c === "/" && value[i + 1] === "*") in_comment = true;
				else if (c === "\"" || c === "'") in_str = c;
				else if (c === "(") in_apo++;
				else if (c === ")") in_apo--;
				if (!in_comment && in_str === false && in_apo === 0) {
					if (c === ":" && name_index === -1) name_index = i;
					else if (c === ";" || i === len - 1) {
						if (name_index !== -1) {
							var name = to_css_name(value.substring(start_index, name_index).trim());
							if (!reserved_names.includes(name)) {
								if (c !== ";") i++;
								var property = value.substring(start_index, i).trim();
								new_style += " " + property + ";";
							}
						}
						start_index = i + 1;
						name_index = -1;
					}
				}
			}
		}
		if (normal_styles) new_style += append_styles(normal_styles);
		if (important_styles) new_style += append_styles(important_styles, true);
		new_style = new_style.trim();
		return new_style === "" ? null : new_style;
	}
	return value == null ? null : String(value);
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/class.js
/**
* @param {Element} dom
* @param {boolean | number} is_html
* @param {string | null} value
* @param {string} [hash]
* @param {Record<string, any>} [prev_classes]
* @param {Record<string, any>} [next_classes]
* @returns {Record<string, boolean> | undefined}
*/
function set_class(dom, is_html, value, hash, prev_classes, next_classes) {
	var prev = dom[CLASS_CACHE];
	if (hydrating || prev !== value || prev === void 0) {
		var next_class_name = to_class(value, hash, next_classes);
		if (!hydrating || next_class_name !== dom.getAttribute("class")) if (next_class_name == null) dom.removeAttribute("class");
		else if (is_html) dom.className = next_class_name;
		else dom.setAttribute("class", next_class_name);
		/** @type {any} */ dom[CLASS_CACHE] = value;
	} else if (next_classes && prev_classes !== next_classes) for (var key in next_classes) {
		var is_present = !!next_classes[key];
		if (prev_classes == null || is_present !== !!prev_classes[key]) dom.classList.toggle(key, is_present);
	}
	return next_classes;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/style.js
/**
* @param {Element & ElementCSSInlineStyle} dom
* @param {Record<string, any>} prev
* @param {Record<string, any>} next
* @param {string} [priority]
*/
function update_styles(dom, prev = {}, next, priority) {
	for (var key in next) {
		var value = next[key];
		if (prev[key] !== value) if (next[key] == null) dom.style.removeProperty(key);
		else dom.style.setProperty(key, value, priority);
	}
}
/**
* @param {Element & ElementCSSInlineStyle} dom
* @param {string | null} value
* @param {Record<string, any> | [Record<string, any>, Record<string, any>]} [prev_styles]
* @param {Record<string, any> | [Record<string, any>, Record<string, any>]} [next_styles]
*/
function set_style(dom, value, prev_styles, next_styles) {
	var prev = dom[STYLE_CACHE];
	if (hydrating || prev !== value) {
		var next_style_attr = to_style(value, next_styles);
		if (!hydrating || next_style_attr !== dom.getAttribute("style")) if (next_style_attr == null) dom.removeAttribute("style");
		else dom.style.cssText = next_style_attr;
		/** @type {any} */ dom[STYLE_CACHE] = value;
	} else if (next_styles) if (Array.isArray(next_styles)) {
		update_styles(dom, prev_styles?.[0], next_styles[0]);
		update_styles(dom, prev_styles?.[1], next_styles[1], "important");
	} else update_styles(dom, prev_styles, next_styles);
	return next_styles;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/bindings/select.js
/**
* Selects the correct option(s) (depending on whether this is a multiple select)
* @template V
* @param {HTMLSelectElement} select
* @param {V} value
* @param {boolean} mounting
*/
function select_option(select, value, mounting = false) {
	if (select.multiple) {
		if (value == void 0) return;
		if (!is_array(value)) return select_multiple_invalid_value();
		for (var option of select.options) option.selected = value.includes(get_option_value(option));
		return;
	}
	for (option of select.options) if (is(get_option_value(option), value)) {
		option.selected = true;
		return;
	}
	if (!mounting || value !== void 0) select.selectedIndex = -1;
}
/**
* Selects the correct option(s) if `value` is given,
* and then sets up a mutation observer to sync the
* current selection to the dom when it changes. Such
* changes could for example occur when options are
* inside an `#each` block.
* @param {HTMLSelectElement} select
*/
function init_select(select) {
	var observer = new MutationObserver(() => {
		select_option(select, select.__value);
	});
	observer.observe(select, {
		childList: true,
		subtree: true,
		attributes: true,
		attributeFilter: ["value"]
	});
	teardown(() => {
		observer.disconnect();
	});
}
/**
* @param {HTMLSelectElement} select
* @param {() => unknown} get
* @param {(value: unknown) => void} set
* @returns {void}
*/
function bind_select_value(select, get, set = get) {
	var batches = /* @__PURE__ */ new WeakSet();
	var mounting = true;
	listen_to_event_and_reset_event(select, "change", (is_reset) => {
		var query = is_reset ? "[selected]" : ":checked";
		/** @type {unknown} */
		var value;
		if (select.multiple) value = [].map.call(select.querySelectorAll(query), get_option_value);
		else {
			/** @type {HTMLOptionElement | null} */
			var selected_option = select.querySelector(query) ?? select.querySelector("option:not([disabled])");
			value = selected_option && get_option_value(selected_option);
		}
		set(value);
		select.__value = value;
		if (current_batch !== null) batches.add(current_batch);
	});
	effect(() => {
		var value = get();
		if (select === document.activeElement) {
			var batch = async_mode_flag ? previous_batch : current_batch;
			if (batches.has(batch)) return;
		}
		select_option(select, value, mounting);
		if (mounting && value === void 0) {
			/** @type {HTMLOptionElement | null} */
			var selected_option = select.querySelector(":checked");
			if (selected_option !== null) {
				value = get_option_value(selected_option);
				set(value);
			}
		}
		select.__value = value;
		mounting = false;
	});
	init_select(select);
}
/** @param {HTMLOptionElement} option */
function get_option_value(option) {
	if ("__value" in option) return option.__value;
	else return option.value;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/attributes.js
/** @import { Blocker, Effect } from '#client' */
var CLASS = Symbol("class");
var STYLE = Symbol("style");
var IS_CUSTOM_ELEMENT = Symbol("is custom element");
var IS_HTML = Symbol("is html");
var LINK_TAG = IS_XHTML ? "link" : "LINK";
var INPUT_TAG = IS_XHTML ? "input" : "INPUT";
var OPTION_TAG = IS_XHTML ? "option" : "OPTION";
var SELECT_TAG = IS_XHTML ? "select" : "SELECT";
var PROGRESS_TAG = IS_XHTML ? "progress" : "PROGRESS";
/**
* The value/checked attribute in the template actually corresponds to the defaultValue property, so we need
* to remove it upon hydration to avoid a bug when someone resets the form value.
* @param {HTMLInputElement} input
* @returns {void}
*/
function remove_input_defaults(input) {
	if (!hydrating) return;
	var already_removed = false;
	var remove_defaults = () => {
		if (already_removed) return;
		already_removed = true;
		if (input.hasAttribute("value")) {
			var value = input.value;
			set_attribute(input, "value", null);
			input.value = value;
		}
		if (input.hasAttribute("checked")) {
			var checked = input.checked;
			set_attribute(input, "checked", null);
			input.checked = checked;
		}
	};
	/** @type {any} */ input[FORM_RESET_HANDLER] = remove_defaults;
	queue_micro_task(remove_defaults);
	add_form_reset_listener();
}
/**
* @param {Element} element
* @param {any} value
*/
function set_value(element, value) {
	var attributes = get_attributes(element);
	if (attributes.value === (attributes.value = value ?? void 0) || element.value === value && (value !== 0 || element.nodeName !== PROGRESS_TAG)) return;
	element.value = value ?? "";
}
/**
* Sets the `selected` attribute on an `option` element.
* Not set through the property because that doesn't reflect to the DOM,
* which means it wouldn't be taken into account when a form is reset.
* @param {HTMLOptionElement} element
* @param {boolean} selected
*/
function set_selected(element, selected) {
	if (selected) {
		if (!element.hasAttribute("selected")) element.setAttribute("selected", "");
	} else element.removeAttribute("selected");
}
/**
* @param {Element} element
* @param {string} attribute
* @param {string | null} value
* @param {boolean} [skip_warning]
*/
function set_attribute(element, attribute, value, skip_warning) {
	var attributes = get_attributes(element);
	if (hydrating) {
		attributes[attribute] = element.getAttribute(attribute);
		if (attribute === "src" || attribute === "srcset" || attribute === "href" && element.nodeName === LINK_TAG) {
			if (!skip_warning);
			return;
		}
	}
	if (attributes[attribute] === (attributes[attribute] = value)) return;
	if (attribute === "loading") element[LOADING_ATTR_SYMBOL] = value;
	if (value == null) element.removeAttribute(attribute);
	else if (typeof value !== "string" && get_setters(element).includes(attribute)) element[attribute] = value;
	else element.setAttribute(attribute, value);
}
/**
* Spreads attributes onto a DOM element, taking into account the currently set attributes
* @param {Element & ElementCSSInlineStyle} element
* @param {Record<string | symbol, any> | undefined} prev
* @param {Record<string | symbol, any>} next New attributes - this function mutates this object
* @param {string} [css_hash]
* @param {boolean} [should_remove_defaults]
* @param {boolean} [skip_warning]
* @returns {Record<string, any>}
*/
function set_attributes(element, prev, next, css_hash, should_remove_defaults = false, skip_warning = false) {
	if (hydrating && should_remove_defaults && element.nodeName === INPUT_TAG) {
		var input = element;
		if (!((input.type === "checkbox" ? "defaultChecked" : "defaultValue") in next)) remove_input_defaults(input);
	}
	var attributes = get_attributes(element);
	var is_custom_element = attributes[IS_CUSTOM_ELEMENT];
	var preserve_attribute_case = !attributes[IS_HTML];
	let is_hydrating_custom_element = hydrating && is_custom_element;
	if (is_hydrating_custom_element) set_hydrating(false);
	var current = prev || {};
	var is_option_element = element.nodeName === OPTION_TAG;
	for (var key in prev) if (!(key in next)) next[key] = null;
	if (next.class) next.class = clsx(next.class);
	else if (css_hash || next[CLASS]) next.class = null;
	if (next[STYLE]) next.style ??= null;
	var setters = get_setters(element);
	for (const key in next) {
		let value = next[key];
		if (is_option_element && key === "value" && value == null) {
			element.value = element.__value = "";
			current[key] = value;
			continue;
		}
		if (key === "class") {
			set_class(element, element.namespaceURI === "http://www.w3.org/1999/xhtml", value, css_hash, prev?.[CLASS], next[CLASS]);
			current[key] = value;
			current[CLASS] = next[CLASS];
			continue;
		}
		if (key === "style") {
			set_style(element, value, prev?.[STYLE], next[STYLE]);
			current[key] = value;
			current[STYLE] = next[STYLE];
			continue;
		}
		var prev_value = current[key];
		if (value === prev_value && !(value === void 0 && element.hasAttribute(key))) continue;
		current[key] = value;
		var prefix = key[0] + key[1];
		if (prefix === "$$") continue;
		if (prefix === "on") {
			/** @type {{ capture?: true }} */
			const opts = {};
			const event_handle_key = "$$" + key;
			let event_name = key.slice(2);
			var is_delegated = can_delegate_event(event_name);
			if (is_capture_event(event_name)) {
				event_name = event_name.slice(0, -7);
				opts.capture = true;
			}
			if (!is_delegated && prev_value) {
				if (value != null) continue;
				element.removeEventListener(event_name, current[event_handle_key], opts);
				current[event_handle_key] = null;
			}
			if (is_delegated) {
				delegated(event_name, element, value);
				delegate([event_name]);
			} else if (value != null) {
				/**
				* @this {any}
				* @param {Event} evt
				*/
				function handle(evt) {
					current[key].call(this, evt);
				}
				current[event_handle_key] = create_event(event_name, element, handle, opts);
			}
		} else if (key === "style") set_attribute(element, key, value);
		else if (key === "autofocus") autofocus(element, Boolean(value));
		else if (!is_custom_element && (key === "__value" || key === "value" && value != null)) element.value = element.__value = value;
		else if (key === "selected" && is_option_element) set_selected(element, value);
		else {
			var name = key;
			if (!preserve_attribute_case) name = normalize_attribute(name);
			var is_default = name === "defaultValue" || name === "defaultChecked";
			if (value == null && !is_custom_element && !is_default) {
				attributes[key] = null;
				if (name === "value" || name === "checked") {
					let input = element;
					const use_default = prev === void 0;
					if (name === "value") {
						let previous = input.defaultValue;
						input.removeAttribute(name);
						input.defaultValue = previous;
						input.value = input.__value = use_default ? previous : null;
					} else {
						let previous = input.defaultChecked;
						input.removeAttribute(name);
						input.defaultChecked = previous;
						input.checked = use_default ? previous : false;
					}
				} else element.removeAttribute(key);
			} else if (is_default || setters.includes(name) && (is_custom_element || typeof value !== "string")) {
				element[name] = value;
				if (name in attributes) attributes[name] = UNINITIALIZED;
			} else if (typeof value !== "function") set_attribute(element, name, value, skip_warning);
		}
	}
	if (is_hydrating_custom_element) set_hydrating(true);
	return current;
}
/**
* @param {Element & ElementCSSInlineStyle} element
* @param {(...expressions: any) => Record<string | symbol, any>} fn
* @param {Array<() => any>} sync
* @param {Array<() => Promise<any>>} async
* @param {Blocker[]} blockers
* @param {string} [css_hash]
* @param {boolean} [should_remove_defaults]
* @param {boolean} [skip_warning]
*/
function attribute_effect(element, fn, sync = [], async = [], blockers = [], css_hash, should_remove_defaults = false, skip_warning = false) {
	flatten(blockers, sync, async, (values) => {
		/** @type {Record<string | symbol, any> | undefined} */
		var prev = void 0;
		/** @type {Record<symbol, Effect>} */
		var effects = {};
		var is_select = element.nodeName === SELECT_TAG;
		var inited = false;
		managed(() => {
			var next = fn(...values.map(get));
			/** @type {Record<string | symbol, any>} */
			var current = set_attributes(element, prev, next, css_hash, should_remove_defaults, skip_warning);
			if (inited && is_select && "value" in next) select_option(element, next.value);
			for (let symbol of Object.getOwnPropertySymbols(effects)) if (!next[symbol]) destroy_effect(effects[symbol]);
			for (let symbol of Object.getOwnPropertySymbols(next)) {
				var n = next[symbol];
				if (symbol.description === "@attach" && (!prev || n !== prev[symbol])) {
					if (effects[symbol]) destroy_effect(effects[symbol]);
					effects[symbol] = branch(() => attach(element, () => n));
				}
				current[symbol] = n;
			}
			prev = current;
		});
		if (is_select) {
			var select = element;
			effect(() => {
				select_option(
					select,
					/** @type {Record<string | symbol, any>} */
					prev.value,
					true
				);
				init_select(select);
			});
		}
		inited = true;
	});
}
/**
*
* @param {Element} element
*/
function get_attributes(element) {
	return element[ATTRIBUTES_CACHE] ??= {
		[IS_CUSTOM_ELEMENT]: element.nodeName.includes("-"),
		[IS_HTML]: element.namespaceURI === NAMESPACE_HTML
	};
}
/** @type {Map<string, string[]>} */
var setters_cache = /* @__PURE__ */ new Map();
/** @param {Element} element */
function get_setters(element) {
	var cache_key = element.getAttribute("is") || element.nodeName;
	var setters = setters_cache.get(cache_key);
	if (setters) return setters;
	setters_cache.set(cache_key, setters = []);
	var descriptors;
	var proto = element;
	var element_proto = Element.prototype;
	while (element_proto !== proto) {
		descriptors = get_descriptors(proto);
		for (var key in descriptors) if (descriptors[key].set && key !== "innerHTML" && key !== "textContent" && key !== "innerText") setters.push(key);
		proto = get_prototype_of(proto);
	}
	return setters;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/elements/bindings/input.js
/** @import { Batch } from '../../../reactivity/batch.js' */
/**
* @param {HTMLInputElement} input
* @param {() => unknown} get
* @param {(value: unknown) => void} set
* @returns {void}
*/
function bind_value(input, get, set = get) {
	var batches = /* @__PURE__ */ new WeakSet();
	listen_to_event_and_reset_event(input, "input", async (is_reset) => {
		/** @type {any} */
		var value = is_reset ? input.defaultValue : input.value;
		value = is_numberlike_input(input) ? to_number(value) : value;
		set(value);
		if (current_batch !== null) batches.add(current_batch);
		await tick();
		if (value !== (value = get())) {
			var start = input.selectionStart;
			var end = input.selectionEnd;
			var length = input.value.length;
			input.value = value ?? "";
			if (end !== null) {
				var new_length = input.value.length;
				if (start === end && end === length && new_length > length) {
					input.selectionStart = new_length;
					input.selectionEnd = new_length;
				} else {
					input.selectionStart = start;
					input.selectionEnd = Math.min(end, new_length);
				}
			}
		}
	});
	if (hydrating && input.defaultValue !== input.value || untrack(get) == null && input.value) {
		set(is_numberlike_input(input) ? to_number(input.value) : input.value);
		if (current_batch !== null) batches.add(current_batch);
	}
	render_effect(() => {
		var value = get();
		if (input === document.activeElement) {
			var batch = async_mode_flag ? previous_batch : current_batch;
			if (batches.has(batch)) return;
		}
		if (is_numberlike_input(input) && value === to_number(input.value)) return;
		if (input.type === "date" && !value && !input.value) return;
		if (value !== input.value) input.value = value ?? "";
	});
}
/**
* @param {HTMLInputElement} input
*/
function is_numberlike_input(input) {
	var type = input.type;
	return type === "number" || type === "range";
}
/**
* @param {string} value
*/
function to_number(value) {
	return value === "" ? null : +value;
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/dom/legacy/lifecycle.js
/** @import { ComponentContextLegacy } from '#client' */
/**
* Legacy-mode only: Call `onMount` callbacks and set up `beforeUpdate`/`afterUpdate` effects
* @param {boolean} [immutable]
*/
function init(immutable = false) {
	const context = component_context;
	const callbacks = context.l.u;
	if (!callbacks) return;
	let props = () => deep_read_state(context.s);
	if (immutable) {
		let version = 0;
		let prev = {};
		const d = /* @__PURE__ */ derived(() => {
			let changed = false;
			const props = context.s;
			for (const key in props) if (props[key] !== prev[key]) {
				prev[key] = props[key];
				changed = true;
			}
			if (changed) version++;
			return version;
		});
		props = () => get(d);
	}
	if (callbacks.b.length) user_pre_effect(() => {
		observe_all(context, props);
		run_all(callbacks.b);
	});
	user_effect(() => {
		const fns = untrack(() => callbacks.m.map(run));
		return () => {
			for (const fn of fns) if (typeof fn === "function") fn();
		};
	});
	if (callbacks.a.length) user_effect(() => {
		observe_all(context, props);
		run_all(callbacks.a);
	});
}
/**
* Invoke the getter of all signals associated with a component
* so they can be registered to the effect this function is called in.
* @param {ComponentContextLegacy} context
* @param {(() => void)} props
*/
function observe_all(context, props) {
	if (context.l.s) for (const signal of context.l.s) get(signal);
	props();
}
//#endregion
//#region node_modules/.pnpm/svelte@5.55.7/node_modules/svelte/src/internal/client/reactivity/props.js
/** @import { Derived, Effect, Source } from './types.js' */
/**
* The proxy handler for rest props (i.e. `const { x, ...rest } = $props()`).
* Is passed the full `$$props` object and excludes the named props.
* @type {ProxyHandler<{ props: Record<string | symbol, unknown>, exclude: Array<string | symbol>, name?: string }>}}
*/
var rest_props_handler = {
	get(target, key) {
		if (target.exclude.includes(key)) return;
		return target.props[key];
	},
	set(target, key) {
		return false;
	},
	getOwnPropertyDescriptor(target, key) {
		if (target.exclude.includes(key)) return;
		if (key in target.props) return {
			enumerable: true,
			configurable: true,
			value: target.props[key]
		};
	},
	has(target, key) {
		if (target.exclude.includes(key)) return false;
		return key in target.props;
	},
	ownKeys(target) {
		return Reflect.ownKeys(target.props).filter((key) => !target.exclude.includes(key));
	}
};
/**
* @param {Record<string, unknown>} props
* @param {string[]} exclude
* @param {string} [name]
* @returns {Record<string, unknown>}
*/
/* @__NO_SIDE_EFFECTS__ */
function rest_props(props, exclude, name) {
	return new Proxy({
		props,
		exclude
	}, rest_props_handler);
}
/**
* The proxy handler for spread props. Handles the incoming array of props
* that looks like `() => { dynamic: props }, { static: prop }, ..` and wraps
* them so that the whole thing is passed to the component as the `$$props` argument.
* @type {ProxyHandler<{ props: Array<Record<string | symbol, unknown> | (() => Record<string | symbol, unknown>)> }>}}
*/
var spread_props_handler = {
	get(target, key) {
		let i = target.props.length;
		while (i--) {
			let p = target.props[i];
			if (is_function(p)) p = p();
			if (typeof p === "object" && p !== null && key in p) return p[key];
		}
	},
	set(target, key, value) {
		let i = target.props.length;
		while (i--) {
			let p = target.props[i];
			if (is_function(p)) p = p();
			const desc = get_descriptor(p, key);
			if (desc && desc.set) {
				desc.set(value);
				return true;
			}
		}
		return false;
	},
	getOwnPropertyDescriptor(target, key) {
		let i = target.props.length;
		while (i--) {
			let p = target.props[i];
			if (is_function(p)) p = p();
			if (typeof p === "object" && p !== null && key in p) {
				const descriptor = get_descriptor(p, key);
				if (descriptor && !descriptor.configurable) descriptor.configurable = true;
				return descriptor;
			}
		}
	},
	has(target, key) {
		if (key === STATE_SYMBOL || key === LEGACY_PROPS) return false;
		for (let p of target.props) {
			if (is_function(p)) p = p();
			if (p != null && key in p) return true;
		}
		return false;
	},
	ownKeys(target) {
		/** @type {Array<string | symbol>} */
		const keys = [];
		for (let p of target.props) {
			if (is_function(p)) p = p();
			if (!p) continue;
			for (const key in p) if (!keys.includes(key)) keys.push(key);
			for (const key of Object.getOwnPropertySymbols(p)) if (!keys.includes(key)) keys.push(key);
		}
		return keys;
	}
};
/**
* @param {Array<Record<string, unknown> | (() => Record<string, unknown>)>} props
* @returns {any}
*/
function spread_props(...props) {
	return new Proxy({ props }, spread_props_handler);
}
/**
* This function is responsible for synchronizing a possibly bound prop with the inner component state.
* It is used whenever the compiler sees that the component writes to the prop, or when it has a default prop_value.
* @template V
* @param {Record<string, unknown>} props
* @param {string} key
* @param {number} flags
* @param {V | (() => V)} [fallback]
* @returns {(() => V | ((arg: V) => V) | ((arg: V, mutation: boolean) => V))}
*/
function prop(props, key, flags, fallback) {
	var runes = !legacy_mode_flag || (flags & 2) !== 0;
	var bindable = (flags & 8) !== 0;
	var lazy = (flags & 16) !== 0;
	var fallback_value = fallback;
	var fallback_dirty = true;
	var fallback_signal = void 0;
	var get_fallback = () => {
		if (lazy && runes) {
			fallback_signal ??= /* @__PURE__ */ derived(fallback);
			return get(fallback_signal);
		}
		if (fallback_dirty) {
			fallback_dirty = false;
			fallback_value = lazy ? untrack(fallback) : fallback;
		}
		return fallback_value;
	};
	/** @type {((v: V) => void) | undefined} */
	let setter;
	if (bindable) {
		var is_entry_props = STATE_SYMBOL in props || LEGACY_PROPS in props;
		setter = get_descriptor(props, key)?.set ?? (is_entry_props && key in props ? (v) => props[key] = v : void 0);
	}
	/** @type {V} */
	var initial_value;
	var is_store_sub = false;
	if (bindable) [initial_value, is_store_sub] = capture_store_binding(() => props[key]);
	else initial_value = props[key];
	if (initial_value === void 0 && fallback !== void 0) {
		initial_value = get_fallback();
		if (setter) {
			if (runes) props_invalid_value(key);
			setter(initial_value);
		}
	}
	/** @type {() => V} */
	var getter;
	if (runes) getter = () => {
		var value = props[key];
		if (value === void 0) return get_fallback();
		fallback_dirty = true;
		return value;
	};
	else getter = () => {
		var value = props[key];
		if (value !== void 0) fallback_value = void 0;
		return value === void 0 ? fallback_value : value;
	};
	if (runes && (flags & 4) === 0) return getter;
	if (setter) {
		var legacy_parent = props.$$legacy;
		return (function(value, mutation) {
			if (arguments.length > 0) {
				if (!runes || !mutation || legacy_parent || is_store_sub)
 /** @type {Function} */ setter(mutation ? getter() : value);
				return value;
			}
			return getter();
		});
	}
	var overridden = false;
	var d = ((flags & 1) !== 0 ? derived : derived_safe_equal)(() => {
		overridden = false;
		return getter();
	});
	if (bindable) get(d);
	var parent_effect = active_effect;
	return (function(value, mutation) {
		if (arguments.length > 0) {
			const new_value = mutation ? get(d) : runes && bindable ? proxy(value) : value;
			set(d, new_value);
			overridden = true;
			if (fallback_value !== void 0) fallback_value = new_value;
			return value;
		}
		if (is_destroying_effect && overridden || (parent_effect.f & 16384) !== 0) return d.v;
		return get(d);
	});
}
if (typeof HTMLElement === "function");
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/is.js
function isObject(value) {
	return value !== null && typeof value === "object";
}
var CLASS_VALUE_PRIMITIVE_TYPES = [
	"string",
	"number",
	"bigint",
	"boolean"
];
function isClassValue(value) {
	if (value === null || value === void 0) return true;
	if (CLASS_VALUE_PRIMITIVE_TYPES.includes(typeof value)) return true;
	if (Array.isArray(value)) return value.every((item) => isClassValue(item));
	if (typeof value === "object") {
		if (Object.getPrototypeOf(value) !== Object.prototype) return false;
		return true;
	}
	return false;
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/box/box-extras.svelte.js
var BoxSymbol = Symbol("box");
var isWritableSymbol = Symbol("is-writable");
function boxWith(getter, setter) {
	const derived = /* @__PURE__ */ user_derived(getter);
	if (setter) return {
		[BoxSymbol]: true,
		[isWritableSymbol]: true,
		get current() {
			return get(derived);
		},
		set current(v) {
			setter(v);
		}
	};
	return {
		[BoxSymbol]: true,
		get current() {
			return getter();
		}
	};
}
/**
* @returns Whether the value is a Box
*
* @see {@link https://runed.dev/docs/functions/box}
*/
function isBox(value) {
	return isObject(value) && BoxSymbol in value;
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/compose-handlers.js
/**
* Composes event handlers into a single function that can be called with an event.
* If the previous handler cancels the event using `event.preventDefault()`, the handlers
* that follow will not be called.
*/
function composeHandlers(...handlers) {
	return function(e) {
		for (const handler of handlers) {
			if (!handler) continue;
			if (e.defaultPrevented) return;
			if (typeof handler === "function") handler.call(this, e);
			else handler.current?.call(this, e);
		}
	};
}
//#endregion
//#region node_modules/.pnpm/inline-style-parser@0.2.7/node_modules/inline-style-parser/esm/index.mjs
var COMMENT_REGEX = /\/\*[^*]*\*+([^/*][^*]*\*+)*\//g;
var NEWLINE_REGEX = /\n/g;
var WHITESPACE_REGEX = /^\s*/;
var PROPERTY_REGEX = /^(\*?[-#/*\\\w]+(\[[0-9a-z_-]+\])?)\s*/;
var COLON_REGEX = /^:\s*/;
var VALUE_REGEX = /^((?:'(?:\\'|.)*?'|"(?:\\"|.)*?"|\([^)]*?\)|[^};])+)/;
var SEMICOLON_REGEX = /^[;\s]*/;
var TRIM_REGEX = /^\s+|\s+$/g;
var NEWLINE = "\n";
var FORWARD_SLASH = "/";
var ASTERISK = "*";
var EMPTY_STRING = "";
var TYPE_COMMENT = "comment";
var TYPE_DECLARATION = "declaration";
/**
* @param {String} style
* @param {Object} [options]
* @return {Object[]}
* @throws {TypeError}
* @throws {Error}
*/
function index(style, options) {
	if (typeof style !== "string") throw new TypeError("First argument must be a string");
	if (!style) return [];
	options = options || {};
	/**
	* Positional.
	*/
	var lineno = 1;
	var column = 1;
	/**
	* Update lineno and column based on `str`.
	*
	* @param {String} str
	*/
	function updatePosition(str) {
		var lines = str.match(NEWLINE_REGEX);
		if (lines) lineno += lines.length;
		var i = str.lastIndexOf(NEWLINE);
		column = ~i ? str.length - i : column + str.length;
	}
	/**
	* Mark position and patch `node.position`.
	*
	* @return {Function}
	*/
	function position() {
		var start = {
			line: lineno,
			column
		};
		return function(node) {
			node.position = new Position(start);
			whitespace();
			return node;
		};
	}
	/**
	* Store position information for a node.
	*
	* @constructor
	* @property {Object} start
	* @property {Object} end
	* @property {undefined|String} source
	*/
	function Position(start) {
		this.start = start;
		this.end = {
			line: lineno,
			column
		};
		this.source = options.source;
	}
	/**
	* Non-enumerable source string.
	*/
	Position.prototype.content = style;
	/**
	* Error `msg`.
	*
	* @param {String} msg
	* @throws {Error}
	*/
	function error(msg) {
		var err = /* @__PURE__ */ new Error(options.source + ":" + lineno + ":" + column + ": " + msg);
		err.reason = msg;
		err.filename = options.source;
		err.line = lineno;
		err.column = column;
		err.source = style;
		if (options.silent);
		else throw err;
	}
	/**
	* Match `re` and return captures.
	*
	* @param {RegExp} re
	* @return {undefined|Array}
	*/
	function match(re) {
		var m = re.exec(style);
		if (!m) return;
		var str = m[0];
		updatePosition(str);
		style = style.slice(str.length);
		return m;
	}
	/**
	* Parse whitespace.
	*/
	function whitespace() {
		match(WHITESPACE_REGEX);
	}
	/**
	* Parse comments.
	*
	* @param {Object[]} [rules]
	* @return {Object[]}
	*/
	function comments(rules) {
		var c;
		rules = rules || [];
		while (c = comment()) if (c !== false) rules.push(c);
		return rules;
	}
	/**
	* Parse comment.
	*
	* @return {Object}
	* @throws {Error}
	*/
	function comment() {
		var pos = position();
		if (FORWARD_SLASH != style.charAt(0) || ASTERISK != style.charAt(1)) return;
		var i = 2;
		while (EMPTY_STRING != style.charAt(i) && (ASTERISK != style.charAt(i) || FORWARD_SLASH != style.charAt(i + 1))) ++i;
		i += 2;
		if (EMPTY_STRING === style.charAt(i - 1)) return error("End of comment missing");
		var str = style.slice(2, i - 2);
		column += 2;
		updatePosition(str);
		style = style.slice(i);
		column += 2;
		return pos({
			type: TYPE_COMMENT,
			comment: str
		});
	}
	/**
	* Parse declaration.
	*
	* @return {Object}
	* @throws {Error}
	*/
	function declaration() {
		var pos = position();
		var prop = match(PROPERTY_REGEX);
		if (!prop) return;
		comment();
		if (!match(COLON_REGEX)) return error("property missing ':'");
		var val = match(VALUE_REGEX);
		var ret = pos({
			type: TYPE_DECLARATION,
			property: trim(prop[0].replace(COMMENT_REGEX, EMPTY_STRING)),
			value: val ? trim(val[0].replace(COMMENT_REGEX, EMPTY_STRING)) : EMPTY_STRING
		});
		match(SEMICOLON_REGEX);
		return ret;
	}
	/**
	* Parse declarations.
	*
	* @return {Object[]}
	*/
	function declarations() {
		var decls = [];
		comments(decls);
		var decl;
		while (decl = declaration()) if (decl !== false) {
			decls.push(decl);
			comments(decls);
		}
		return decls;
	}
	whitespace();
	return declarations();
}
/**
* Trim `str`.
*
* @param {String} str
* @return {String}
*/
function trim(str) {
	return str ? str.replace(TRIM_REGEX, EMPTY_STRING) : EMPTY_STRING;
}
//#endregion
//#region node_modules/.pnpm/style-to-object@1.0.14/node_modules/style-to-object/esm/index.mjs
/**
* Parses inline style to object.
*
* @param style - Inline style.
* @param iterator - Iterator.
* @returns - Style object or null.
*
* @example Parsing inline style to object:
*
* ```js
* import parse from 'style-to-object';
* parse('line-height: 42;'); // { 'line-height': '42' }
* ```
*/
function StyleToObject(style, iterator) {
	let styleObject = null;
	if (!style || typeof style !== "string") return styleObject;
	const declarations = index(style);
	const hasIterator = typeof iterator === "function";
	declarations.forEach((declaration) => {
		if (declaration.type !== "declaration") return;
		const { property, value } = declaration;
		if (hasIterator) iterator(property, value, declaration);
		else if (value) {
			styleObject = styleObject || {};
			styleObject[property] = value;
		}
	});
	return styleObject;
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/strings.js
var NUMBER_CHAR_RE = /\d/;
var STR_SPLITTERS = [
	"-",
	"_",
	"/",
	"."
];
function isUppercase(char = "") {
	if (NUMBER_CHAR_RE.test(char)) return void 0;
	return char !== char.toLowerCase();
}
function splitByCase(str) {
	const parts = [];
	let buff = "";
	let previousUpper;
	let previousSplitter;
	for (const char of str) {
		const isSplitter = STR_SPLITTERS.includes(char);
		if (isSplitter === true) {
			parts.push(buff);
			buff = "";
			previousUpper = void 0;
			continue;
		}
		const isUpper = isUppercase(char);
		if (previousSplitter === false) {
			if (previousUpper === false && isUpper === true) {
				parts.push(buff);
				buff = char;
				previousUpper = isUpper;
				continue;
			}
			if (previousUpper === true && isUpper === false && buff.length > 1) {
				const lastChar = buff.at(-1);
				parts.push(buff.slice(0, Math.max(0, buff.length - 1)));
				buff = lastChar + char;
				previousUpper = isUpper;
				continue;
			}
		}
		buff += char;
		previousUpper = isUpper;
		previousSplitter = isSplitter;
	}
	parts.push(buff);
	return parts;
}
function pascalCase(str) {
	if (!str) return "";
	return splitByCase(str).map((p) => upperFirst(p)).join("");
}
function camelCase(str) {
	return lowerFirst(pascalCase(str || ""));
}
function upperFirst(str) {
	return str ? str[0].toUpperCase() + str.slice(1) : "";
}
function lowerFirst(str) {
	return str ? str[0].toLowerCase() + str.slice(1) : "";
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/css-to-style-obj.js
function cssToStyleObj(css) {
	if (!css) return {};
	const styleObj = {};
	function iterator(name, value) {
		if (name.startsWith("-moz-") || name.startsWith("-webkit-") || name.startsWith("-ms-") || name.startsWith("-o-")) {
			styleObj[pascalCase(name)] = value;
			return;
		}
		if (name.startsWith("--")) {
			styleObj[name] = value;
			return;
		}
		styleObj[camelCase(name)] = value;
	}
	StyleToObject(css, iterator);
	return styleObj;
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/execute-callbacks.js
/**
* Executes an array of callback functions with the same arguments.
* @template T The types of the arguments that the callback functions take.
* @param callbacks array of callback functions to execute.
* @returns A new function that executes all of the original callback functions with the same arguments.
*/
function executeCallbacks(...callbacks) {
	return (...args) => {
		for (const callback of callbacks) if (typeof callback === "function") callback(...args);
	};
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/style-to-css.js
function createParser(matcher, replacer) {
	const regex = RegExp(matcher, "g");
	return (str) => {
		if (typeof str !== "string") throw new TypeError(`expected an argument of type string, but got ${typeof str}`);
		if (!str.match(regex)) return str;
		return str.replace(regex, replacer);
	};
}
var camelToKebab = createParser(/[A-Z]/, (match) => `-${match.toLowerCase()}`);
function styleToCSS(styleObj) {
	if (!styleObj || typeof styleObj !== "object" || Array.isArray(styleObj)) throw new TypeError(`expected an argument of type object, but got ${typeof styleObj}`);
	return Object.keys(styleObj).map((property) => `${camelToKebab(property)}: ${styleObj[property]};`).join("\n");
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/style.js
function styleToString(style = {}) {
	return styleToCSS(style).replace("\n", " ");
}
var EVENT_LIST_SET = new Set([
	"onabort",
	"onanimationcancel",
	"onanimationend",
	"onanimationiteration",
	"onanimationstart",
	"onauxclick",
	"onbeforeinput",
	"onbeforetoggle",
	"onblur",
	"oncancel",
	"oncanplay",
	"oncanplaythrough",
	"onchange",
	"onclick",
	"onclose",
	"oncompositionend",
	"oncompositionstart",
	"oncompositionupdate",
	"oncontextlost",
	"oncontextmenu",
	"oncontextrestored",
	"oncopy",
	"oncuechange",
	"oncut",
	"ondblclick",
	"ondrag",
	"ondragend",
	"ondragenter",
	"ondragleave",
	"ondragover",
	"ondragstart",
	"ondrop",
	"ondurationchange",
	"onemptied",
	"onended",
	"onerror",
	"onfocus",
	"onfocusin",
	"onfocusout",
	"onformdata",
	"ongotpointercapture",
	"oninput",
	"oninvalid",
	"onkeydown",
	"onkeypress",
	"onkeyup",
	"onload",
	"onloadeddata",
	"onloadedmetadata",
	"onloadstart",
	"onlostpointercapture",
	"onmousedown",
	"onmouseenter",
	"onmouseleave",
	"onmousemove",
	"onmouseout",
	"onmouseover",
	"onmouseup",
	"onpaste",
	"onpause",
	"onplay",
	"onplaying",
	"onpointercancel",
	"onpointerdown",
	"onpointerenter",
	"onpointerleave",
	"onpointermove",
	"onpointerout",
	"onpointerover",
	"onpointerup",
	"onprogress",
	"onratechange",
	"onreset",
	"onresize",
	"onscroll",
	"onscrollend",
	"onsecuritypolicyviolation",
	"onseeked",
	"onseeking",
	"onselect",
	"onselectionchange",
	"onselectstart",
	"onslotchange",
	"onstalled",
	"onsubmit",
	"onsuspend",
	"ontimeupdate",
	"ontoggle",
	"ontouchcancel",
	"ontouchend",
	"ontouchmove",
	"ontouchstart",
	"ontransitioncancel",
	"ontransitionend",
	"ontransitionrun",
	"ontransitionstart",
	"onvolumechange",
	"onwaiting",
	"onwebkitanimationend",
	"onwebkitanimationiteration",
	"onwebkitanimationstart",
	"onwebkittransitionend",
	"onwheel"
]);
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/merge-props.js
/**
* Modified from https://github.com/adobe/react-spectrum/blob/main/packages/%40react-aria/utils/src/mergeProps.ts (see NOTICE.txt for source)
*/
function isEventHandler(key) {
	return EVENT_LIST_SET.has(key);
}
/**
* Given a list of prop objects, merges them into a single object.
* - Automatically composes event handlers (e.g. `onclick`, `oninput`, etc.)
* - Chains regular functions with the same name so they are called in order
* - Merges class strings with `clsx`
* - Merges style objects and converts them to strings
* - Handles a bug with Svelte where setting the `hidden` attribute to `false` doesn't remove it
* - Overrides other values with the last one
*/
function mergeProps(...args) {
	const result = { ...args[0] };
	for (let i = 1; i < args.length; i++) {
		const props = args[i];
		if (!props) continue;
		for (const key of Object.keys(props)) {
			const a = result[key];
			const b = props[key];
			const aIsFunction = typeof a === "function";
			const bIsFunction = typeof b === "function";
			if (aIsFunction && typeof bIsFunction && isEventHandler(key)) result[key] = composeHandlers(a, b);
			else if (aIsFunction && bIsFunction) result[key] = executeCallbacks(a, b);
			else if (key === "class") {
				const aIsClassValue = isClassValue(a);
				const bIsClassValue = isClassValue(b);
				if (aIsClassValue && bIsClassValue) result[key] = clsx$1(a, b);
				else if (aIsClassValue) result[key] = clsx$1(a);
				else if (bIsClassValue) result[key] = clsx$1(b);
			} else if (key === "style") {
				const aIsObject = typeof a === "object";
				const bIsObject = typeof b === "object";
				const aIsString = typeof a === "string";
				const bIsString = typeof b === "string";
				if (aIsObject && bIsObject) result[key] = {
					...a,
					...b
				};
				else if (aIsObject && bIsString) {
					const parsedStyle = cssToStyleObj(b);
					result[key] = {
						...a,
						...parsedStyle
					};
				} else if (aIsString && bIsObject) result[key] = {
					...cssToStyleObj(a),
					...b
				};
				else if (aIsString && bIsString) {
					const parsedStyleA = cssToStyleObj(a);
					const parsedStyleB = cssToStyleObj(b);
					result[key] = {
						...parsedStyleA,
						...parsedStyleB
					};
				} else if (aIsObject) result[key] = a;
				else if (bIsObject) result[key] = b;
				else if (aIsString) result[key] = a;
				else if (bIsString) result[key] = b;
			} else result[key] = b !== void 0 ? b : a;
		}
		for (const key of Object.getOwnPropertySymbols(props)) {
			const a = result[key];
			const b = props[key];
			result[key] = b !== void 0 ? b : a;
		}
	}
	if (typeof result.style === "object") result.style = styleToString(result.style).replaceAll("\n", " ");
	if (result.hidden === false) {
		result.hidden = void 0;
		delete result.hidden;
	}
	if (result.disabled === false) {
		result.disabled = void 0;
		delete result.disabled;
	}
	return result;
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/sr-only-styles.js
var srOnlyStyles = {
	position: "absolute",
	width: "1px",
	height: "1px",
	padding: "0",
	margin: "-1px",
	overflow: "hidden",
	clip: "rect(0, 0, 0, 0)",
	whiteSpace: "nowrap",
	borderWidth: "0",
	transform: "translateX(-100%)"
};
styleToString(srOnlyStyles);
//#endregion
//#region node_modules/.pnpm/runed@0.35.1_svelte@5.55.7/node_modules/runed/dist/internal/configurable-globals.js
var defaultWindow = typeof window !== "undefined" ? window : void 0;
typeof window !== "undefined" && window.document;
typeof window !== "undefined" && window.navigator;
typeof window !== "undefined" && window.location;
//#endregion
//#region node_modules/.pnpm/runed@0.35.1_svelte@5.55.7/node_modules/runed/dist/internal/utils/dom.js
/**
* Handles getting the active element in a document or shadow root.
* If the active element is within a shadow root, it will traverse the shadow root
* to find the active element.
* If not, it will return the active element in the document.
*
* @param document A document or shadow root to get the active element from.
* @returns The active element in the document or shadow root.
*/
function getActiveElement$1(document) {
	let activeElement = document.activeElement;
	while (activeElement?.shadowRoot) {
		const node = activeElement.shadowRoot.activeElement;
		if (node === activeElement) break;
		else activeElement = node;
	}
	return activeElement;
}
//#endregion
//#region node_modules/.pnpm/runed@0.35.1_svelte@5.55.7/node_modules/runed/dist/utilities/active-element/active-element.svelte.js
var ActiveElement = class {
	#document;
	#subscribe;
	constructor(options = {}) {
		const { window = defaultWindow, document = window?.document } = options;
		if (window === void 0) return;
		this.#document = document;
		this.#subscribe = createSubscriber((update) => {
			const cleanupFocusIn = on(window, "focusin", update);
			const cleanupFocusOut = on(window, "focusout", update);
			return () => {
				cleanupFocusIn();
				cleanupFocusOut();
			};
		});
	}
	get current() {
		this.#subscribe?.();
		if (!this.#document) return null;
		return getActiveElement$1(this.#document);
	}
};
new ActiveElement();
//#endregion
//#region node_modules/.pnpm/runed@0.35.1_svelte@5.55.7/node_modules/runed/dist/utilities/context/context.js
var Context = class {
	#name;
	#key;
	/**
	* @param name The name of the context.
	* This is used for generating the context key and error messages.
	*/
	constructor(name) {
		this.#name = name;
		this.#key = Symbol(name);
	}
	/**
	* The key used to get and set the context.
	*
	* It is not recommended to use this value directly.
	* Instead, use the methods provided by this class.
	*/
	get key() {
		return this.#key;
	}
	/**
	* Checks whether this has been set in the context of a parent component.
	*
	* Must be called during component initialisation.
	*/
	exists() {
		return hasContext(this.#key);
	}
	/**
	* Retrieves the context that belongs to the closest parent component.
	*
	* Must be called during component initialisation.
	*
	* @throws An error if the context does not exist.
	*/
	get() {
		const context = getContext(this.#key);
		if (context === void 0) throw new Error(`Context "${this.#name}" not found`);
		return context;
	}
	/**
	* Retrieves the context that belongs to the closest parent component,
	* or the given fallback value if the context does not exist.
	*
	* Must be called during component initialisation.
	*/
	getOr(fallback) {
		const context = getContext(this.#key);
		if (context === void 0) return fallback;
		return context;
	}
	/**
	* Associates the given value with the current component and returns it.
	*
	* Must be called during component initialisation.
	*/
	set(context) {
		return setContext(this.#key, context);
	}
};
//#endregion
//#region node_modules/.pnpm/runed@0.35.1_svelte@5.55.7/node_modules/runed/dist/utilities/watch/watch.svelte.js
function runEffect(flush, effect) {
	switch (flush) {
		case "post":
			user_effect(effect);
			break;
		case "pre":
			user_pre_effect(effect);
			break;
	}
}
function runWatcher(sources, flush, effect, options = {}) {
	const { lazy = false } = options;
	let active = !lazy;
	let previousValues = Array.isArray(sources) ? [] : void 0;
	runEffect(flush, () => {
		const values = Array.isArray(sources) ? sources.map((source) => source()) : sources();
		if (!active) {
			active = true;
			previousValues = values;
			return;
		}
		const cleanup = untrack(() => effect(values, previousValues));
		previousValues = values;
		return cleanup;
	});
}
function runWatcherOnce(sources, flush, effect) {
	const cleanupRoot = effect_root(() => {
		let stop = false;
		runWatcher(sources, flush, (values, previousValues) => {
			if (stop) {
				cleanupRoot();
				return;
			}
			const cleanup = effect(values, previousValues);
			stop = true;
			return cleanup;
		}, { lazy: true });
	});
	user_effect(() => {
		return cleanupRoot;
	});
}
function watch(sources, effect, options) {
	runWatcher(sources, "post", effect, options);
}
function watchPre(sources, effect, options) {
	runWatcher(sources, "pre", effect, options);
}
watch.pre = watchPre;
function watchOnce(source, effect) {
	runWatcherOnce(source, "post", effect);
}
function watchOncePre(source, effect) {
	runWatcherOnce(source, "pre", effect);
}
watchOnce.pre = watchOncePre;
//#endregion
//#region node_modules/.pnpm/runed@0.35.1_svelte@5.55.7/node_modules/runed/dist/utilities/resource/resource.svelte.js
function debounce(fn, delay) {
	let timeoutId;
	let lastResolve = null;
	return (...args) => {
		return new Promise((resolve) => {
			if (lastResolve) lastResolve(void 0);
			lastResolve = resolve;
			clearTimeout(timeoutId);
			timeoutId = setTimeout(async () => {
				const result = await fn(...args);
				if (lastResolve) {
					lastResolve(result);
					lastResolve = null;
				}
			}, delay);
		});
	};
}
function throttle(fn, delay) {
	let lastRun = 0;
	let lastPromise = null;
	return (...args) => {
		const now = Date.now();
		if (lastRun && now - lastRun < delay) return lastPromise ?? Promise.resolve(void 0);
		lastRun = now;
		lastPromise = fn(...args);
		return lastPromise;
	};
}
function runResource(source, fetcher, options = {}, effectFn) {
	const { lazy = false, once = false, initialValue, debounce: debounceTime, throttle: throttleTime } = options;
	let current = /* @__PURE__ */ state(proxy(initialValue));
	let loading = /* @__PURE__ */ state(false);
	let error = /* @__PURE__ */ state(void 0);
	let cleanupFns = /* @__PURE__ */ state(proxy([]));
	const runCleanup = () => {
		get(cleanupFns).forEach((fn) => fn());
		set(cleanupFns, [], true);
	};
	const onCleanup = (fn) => {
		set(cleanupFns, [...get(cleanupFns), fn], true);
	};
	const baseFetcher = async (value, previousValue, refetching = false) => {
		try {
			set(loading, true);
			set(error, void 0);
			runCleanup();
			const controller = new AbortController();
			onCleanup(() => controller.abort());
			const result = await fetcher(value, previousValue, {
				data: get(current),
				refetching,
				onCleanup,
				signal: controller.signal
			});
			set(current, result, true);
			return result;
		} catch (e) {
			if (!(e instanceof DOMException && e.name === "AbortError")) set(error, e, true);
			return;
		} finally {
			set(loading, false);
		}
	};
	const runFetcher = debounceTime ? debounce(baseFetcher, debounceTime) : throttleTime ? throttle(baseFetcher, throttleTime) : baseFetcher;
	const sources = Array.isArray(source) ? source : [source];
	let prevValues;
	effectFn((values, previousValues) => {
		if (once && prevValues) return;
		prevValues = values;
		runFetcher(Array.isArray(source) ? values : values[0], Array.isArray(source) ? previousValues : previousValues?.[0]);
	}, { lazy });
	return {
		get current() {
			return get(current);
		},
		get loading() {
			return get(loading);
		},
		get error() {
			return get(error);
		},
		mutate: (value) => {
			set(current, value, true);
		},
		refetch: (info) => {
			const values = sources.map((s) => s());
			return runFetcher(Array.isArray(source) ? values : values[0], Array.isArray(source) ? values : values[0], info ?? true);
		}
	};
}
function resource(source, fetcher, options) {
	return runResource(source, fetcher, options, (fn, options) => {
		const sources = Array.isArray(source) ? source : [source];
		const getters = () => sources.map((s) => s());
		watch(getters, (values, previousValues) => {
			fn(values, previousValues ?? []);
		}, options);
	});
}
function resourcePre(source, fetcher, options) {
	return runResource(source, fetcher, options, (fn, options) => {
		const sources = Array.isArray(source) ? source : [source];
		const getter = () => sources.map((s) => s());
		watch.pre(getter, (values, previousValues) => {
			fn(values, previousValues ?? []);
		}, options);
	});
}
resource.pre = resourcePre;
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/on-mount-effect.svelte.js
function onMountEffect(fn) {
	user_effect(() => {
		return untrack(() => fn());
	});
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/dom.js
var DOCUMENT_NODE = 9;
function isDocument(node) {
	return isObject(node) && node.nodeType === DOCUMENT_NODE;
}
function isWindow(node) {
	return isObject(node) && node.constructor?.name === "VisualViewport";
}
function getDocument(node) {
	if (isDocument(node)) return node;
	if (isWindow(node)) return node.document;
	return node?.ownerDocument ?? document;
}
function getActiveElement(rootNode) {
	let activeElement = rootNode.activeElement;
	while (activeElement?.shadowRoot) {
		const el = activeElement.shadowRoot.activeElement;
		if (el === activeElement) break;
		else activeElement = el;
	}
	return activeElement;
}
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/dom-context.svelte.js
var DOMContext = class {
	element;
	#root = /* @__PURE__ */ user_derived(() => {
		if (!this.element.current) return document;
		return this.element.current.getRootNode() ?? document;
	});
	get root() {
		return get(this.#root);
	}
	set root(value) {
		set(this.#root, value);
	}
	constructor(element) {
		if (typeof element === "function") this.element = boxWith(element);
		else this.element = element;
	}
	getDocument = () => {
		return getDocument(this.root);
	};
	getWindow = () => {
		return this.getDocument().defaultView ?? window;
	};
	getActiveElement = () => {
		return getActiveElement(this.root);
	};
	isActiveElement = (node) => {
		return node === this.getActiveElement();
	};
	getElementById(id) {
		return this.root.getElementById(id);
	}
	querySelector = (selector) => {
		if (!this.root) return null;
		return this.root.querySelector(selector);
	};
	querySelectorAll = (selector) => {
		if (!this.root) return [];
		return this.root.querySelectorAll(selector);
	};
	setTimeout = (callback, delay) => {
		return this.getWindow().setTimeout(callback, delay);
	};
	clearTimeout = (timeoutId) => {
		return this.getWindow().clearTimeout(timeoutId);
	};
};
//#endregion
//#region node_modules/.pnpm/svelte-toolbelt@0.10.6_svelte@5.55.7/node_modules/svelte-toolbelt/dist/utils/attach-ref.js
/**
* Creates a Svelte Attachment that attaches a DOM element to a ref.
* The ref can be either a WritableBox or a callback function.
*
* @param ref - Either a WritableBox to store the element in, or a callback function that receives the element
* @param onChange - Optional callback that fires when the ref changes
* @returns An object with a spreadable attachment key that should be spread onto the element
*
* @example
* // Using with WritableBox
* const ref = box<HTMLDivElement | null>(null);
* <div {...attachRef(ref)}>Content</div>
*
* @example
* // Using with callback
* <div {...attachRef((node) => myNode = node)}>Content</div>
*
* @example
* // Using with onChange
* <div {...attachRef(ref, (node) => console.log(node))}>Content</div>
*/
function attachRef(ref, onChange) {
	return { [createAttachmentKey()]: (node) => {
		if (isBox(ref)) {
			ref.current = node;
			untrack(() => onChange?.(node));
			return () => {
				if ("isConnected" in node && node.isConnected) return;
				ref.current = null;
				onChange?.(null);
			};
		}
		ref(node);
		untrack(() => onChange?.(node));
		return () => {
			if ("isConnected" in node && node.isConnected) return;
			ref(null);
			onChange?.(null);
		};
	} };
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/internal/attrs.js
function boolToStr(condition) {
	return condition ? "true" : "false";
}
function boolToEmptyStrOrUndef(condition) {
	return condition ? "" : void 0;
}
function boolToTrueOrUndef(condition) {
	return condition ? true : void 0;
}
function getDataChecked(condition) {
	return condition ? "checked" : "unchecked";
}
function getAriaChecked(checked, indeterminate) {
	if (indeterminate) return "mixed";
	return checked ? "true" : "false";
}
var BitsAttrs = class {
	#variant;
	#prefix;
	attrs;
	constructor(config) {
		this.#variant = config.getVariant ? config.getVariant() : null;
		this.#prefix = this.#variant ? `data-${this.#variant}-` : `data-${config.component}-`;
		this.getAttr = this.getAttr.bind(this);
		this.selector = this.selector.bind(this);
		this.attrs = Object.fromEntries(config.parts.map((part) => [part, this.getAttr(part)]));
	}
	getAttr(part, variantOverride) {
		if (variantOverride) return `data-${variantOverride}-${part}`;
		return `${this.#prefix}${part}`;
	}
	selector(part, variantOverride) {
		return `[${this.getAttr(part, variantOverride)}]`;
	}
};
function createBitsAttrs(config) {
	const bitsAttrs = new BitsAttrs(config);
	return {
		...bitsAttrs.attrs,
		selector: bitsAttrs.selector,
		getAttr: bitsAttrs.getAttr
	};
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/internal/kbd-constants.js
var ARROW_DOWN = "ArrowDown";
var ARROW_LEFT = "ArrowLeft";
var ARROW_RIGHT = "ArrowRight";
var ARROW_UP = "ArrowUp";
var HOME = "Home";
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/internal/is.js
var isBrowser = typeof document !== "undefined";
getIsIOS();
function getIsIOS() {
	return isBrowser && window?.navigator?.userAgent && (/iP(ad|hone|od)/.test(window.navigator.userAgent) || window?.navigator?.maxTouchPoints > 2 && /iPad|Macintosh/.test(window?.navigator.userAgent));
}
function isElementOrSVGElement(element) {
	return element instanceof Element || element instanceof SVGElement;
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/internal/noop.js
/**
* A no operation function (does nothing)
*/
function noop() {}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/internal/create-id.js
function createId(prefixOrUid, uid) {
	if (uid === void 0) return `bits-${prefixOrUid}`;
	return `bits-${prefixOrUid}-${uid}`;
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/internal/arrays.js
/**
* Checks if the given index is valid for the given array.
*
* @param index - The index to check
* @param arr - The array to check
*/
function isValidIndex(index, arr) {
	return index >= 0 && index < arr.length;
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/utilities/hidden-input.svelte
var root_1$1 = /* @__PURE__ */ from_html(`<input/>`);
var root_2$6 = /* @__PURE__ */ from_html(`<input/>`);
function Hidden_input($$anchor, $$props) {
	push($$props, true);
	let value = prop($$props, "value", 15), restProps = /* @__PURE__ */ rest_props($$props, [
		"$$slots",
		"$$events",
		"$$legacy",
		"value"
	]);
	const mergedProps = /* @__PURE__ */ user_derived(() => mergeProps(restProps, {
		"aria-hidden": "true",
		tabindex: -1,
		style: {
			...srOnlyStyles,
			position: "absolute",
			top: "0",
			left: "0"
		}
	}));
	var fragment = comment();
	var node = first_child(fragment);
	var consequent = ($$anchor) => {
		var input = root_1$1();
		attribute_effect(input, () => ({
			...get(mergedProps),
			value: value()
		}), void 0, void 0, void 0, void 0, true);
		append($$anchor, input);
	};
	var alternate = ($$anchor) => {
		var input_1 = root_2$6();
		attribute_effect(input_1, () => ({ ...get(mergedProps) }), void 0, void 0, void 0, void 0, true);
		bind_value(input_1, value);
		append($$anchor, input_1);
	};
	if_block(node, ($$render) => {
		if (get(mergedProps).type === "checkbox") $$render(consequent);
		else $$render(alternate, -1);
	});
	append($$anchor, fragment);
	pop();
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/internal/svelte-resize-observer.svelte.js
var SvelteResizeObserver = class {
	#node;
	#onResize;
	constructor(node, onResize) {
		this.#node = node;
		this.#onResize = onResize;
		this.handler = this.handler.bind(this);
		user_effect(this.handler);
	}
	handler() {
		let rAF = 0;
		const _node = this.#node();
		if (!_node) return;
		const resizeObserver = new ResizeObserver(() => {
			cancelAnimationFrame(rAF);
			rAF = window.requestAnimationFrame(this.#onResize);
		});
		resizeObserver.observe(_node);
		return () => {
			window.cancelAnimationFrame(rAF);
			resizeObserver.unobserve(_node);
		};
	}
};
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/slider/helpers.js
function getRangeStyles(direction, min, max) {
	const styles = { position: "absolute" };
	if (direction === "lr") {
		styles.left = `${min}%`;
		styles.right = `${max}%`;
	} else if (direction === "rl") {
		styles.right = `${min}%`;
		styles.left = `${max}%`;
	} else if (direction === "bt") {
		styles.bottom = `${min}%`;
		styles.top = `${max}%`;
	} else {
		styles.top = `${min}%`;
		styles.bottom = `${max}%`;
	}
	return styles;
}
function getThumbStyles(direction, thumbPos) {
	const styles = { position: "absolute" };
	if (direction === "lr") {
		styles.left = `${thumbPos}%`;
		styles.translate = "-50% 0";
	} else if (direction === "rl") {
		styles.right = `${thumbPos}%`;
		styles.translate = "50% 0";
	} else if (direction === "bt") {
		styles.bottom = `${thumbPos}%`;
		styles.translate = "0 50%";
	} else {
		styles.top = `${thumbPos}%`;
		styles.translate = "0 -50%";
	}
	return styles;
}
function getTickStyles(direction, tickPosition, offsetPercentage) {
	const style = { position: "absolute" };
	if (direction === "lr") {
		style.left = `${tickPosition}%`;
		style.translate = `${offsetPercentage}% 0`;
	} else if (direction === "rl") {
		style.right = `${tickPosition}%`;
		style.translate = `${-offsetPercentage}% 0`;
	} else if (direction === "bt") {
		style.bottom = `${tickPosition}%`;
		style.translate = `0 ${-offsetPercentage}%`;
	} else {
		style.top = `${tickPosition}%`;
		style.translate = `0 ${offsetPercentage}%`;
	}
	return style;
}
/**
* Gets the number of decimal places in a number
*/
function getDecimalPlaces(num) {
	if (Math.floor(num) === num) return 0;
	const str = num.toString();
	if (str.indexOf(".") !== -1 && str.indexOf("e-") === -1) return str.split(".")[1].length;
	else if (str.indexOf("e-") !== -1) {
		const parts = str.split("e-");
		return parseInt(parts[1], 10);
	}
	return 0;
}
/**
* Rounds a number to the specified number of decimal places
*/
function roundToPrecision(num, precision) {
	const factor = Math.pow(10, precision);
	return Math.round(num * factor) / factor;
}
/**
* Normalizes step to always be a sorted array of valid values within min/max range
*/
function normalizeSteps(step, min, max) {
	if (typeof step === "number") {
		const difference = max - min;
		let count = Math.ceil(difference / step);
		const precision = getDecimalPlaces(step);
		const factor = Math.pow(10, precision);
		if (Math.round(difference * factor) % Math.round(step * factor) === 0) count++;
		const steps = [];
		for (let i = 0; i < count; i++) {
			const roundedValue = roundToPrecision(min + i * step, precision);
			steps.push(roundedValue);
		}
		return steps;
	}
	return [...new Set(step)].filter((value) => value >= min && value <= max).sort((a, b) => a - b);
}
/**
* Snaps a value to the nearest step in a custom steps array
*/
function snapValueToCustomSteps(value, steps) {
	if (steps.length === 0) return value;
	let closest = steps[0];
	let minDistance = Math.abs(value - closest);
	for (const step of steps) {
		const distance = Math.abs(value - step);
		if (distance < minDistance) {
			minDistance = distance;
			closest = step;
		}
	}
	return closest;
}
/**
* Gets the next/previous step value for keyboard navigation
*/
function getAdjacentStepValue(currentValue, steps, direction) {
	const currentIndex = steps.indexOf(currentValue);
	if (currentIndex === -1) return snapValueToCustomSteps(currentValue, steps);
	if (direction === "next") return currentIndex < steps.length - 1 ? steps[currentIndex + 1] : currentValue;
	else return currentIndex > 0 ? steps[currentIndex - 1] : currentValue;
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/internal/math.js
function linearScale(domain, range, clamp = true) {
	const [d0, d1] = domain;
	const [r0, r1] = range;
	const slope = (r1 - r0) / (d1 - d0);
	return (x) => {
		const result = r0 + slope * (x - d0);
		if (!clamp) return result;
		if (result > Math.max(r0, r1)) return Math.max(r0, r1);
		if (result < Math.min(r0, r1)) return Math.min(r0, r1);
		return result;
	};
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/slider/slider.svelte.js
var sliderAttrs = createBitsAttrs({
	component: "slider",
	parts: [
		"root",
		"thumb",
		"range",
		"tick",
		"tick-label",
		"thumb-label"
	]
});
var SliderRootContext = new Context("Slider.Root");
var SliderBaseRootState = class {
	opts;
	attachment;
	#isActive = /* @__PURE__ */ state(false);
	get isActive() {
		return get(this.#isActive);
	}
	set isActive(value) {
		set(this.#isActive, value, true);
	}
	#layoutVersion = /* @__PURE__ */ state(0);
	#direction = /* @__PURE__ */ user_derived(() => {
		if (this.opts.orientation.current === "horizontal") return this.opts.dir.current === "rtl" ? "rl" : "lr";
		else return this.opts.dir.current === "rtl" ? "tb" : "bt";
	});
	get direction() {
		return get(this.#direction);
	}
	set direction(value) {
		set(this.#direction, value);
	}
	#normalizedSteps = /* @__PURE__ */ user_derived(() => {
		return normalizeSteps(this.opts.step.current, this.opts.min.current, this.opts.max.current);
	});
	get normalizedSteps() {
		return get(this.#normalizedSteps);
	}
	set normalizedSteps(value) {
		set(this.#normalizedSteps, value);
	}
	domContext;
	constructor(opts) {
		this.opts = opts;
		this.attachment = attachRef(opts.ref);
		this.domContext = new DOMContext(this.opts.ref);
		new SvelteResizeObserver(() => this.opts.ref.current, this.#handleLayoutChange);
	}
	#handleLayoutChange = () => {
		set(this.#layoutVersion, get(this.#layoutVersion) + 1);
	};
	isThumbActive(_index) {
		return this.isActive;
	}
	#touchAction = /* @__PURE__ */ user_derived(() => {
		if (this.opts.disabled.current) return void 0;
		return this.opts.orientation.current === "horizontal" ? "pan-y" : "pan-x";
	});
	getAllThumbs = () => {
		const node = this.opts.ref.current;
		if (!node) return [];
		return Array.from(node.querySelectorAll(sliderAttrs.selector("thumb")));
	};
	getThumbScale = () => {
		get(this.#layoutVersion);
		const trackPadding = this.opts.trackPadding?.current;
		if (trackPadding !== void 0 && trackPadding > 0) return [trackPadding, 100 - trackPadding];
		if (this.opts.thumbPositioning.current === "exact") return [0, 100];
		const isVertical = this.opts.orientation.current === "vertical";
		const activeThumb = this.getAllThumbs()[0];
		const thumbSize = isVertical ? activeThumb?.offsetHeight : activeThumb?.offsetWidth;
		if (thumbSize === void 0 || Number.isNaN(thumbSize) || thumbSize === 0) return [0, 100];
		const trackSize = isVertical ? this.opts.ref.current?.offsetHeight : this.opts.ref.current?.offsetWidth;
		if (trackSize === void 0 || Number.isNaN(trackSize) || trackSize === 0) return [0, 100];
		const percentPadding = thumbSize / 2 / trackSize * 100;
		return [percentPadding, 100 - percentPadding];
	};
	getPositionFromValue = (thumbValue) => {
		const thumbScale = this.getThumbScale();
		return linearScale([this.opts.min.current, this.opts.max.current], thumbScale)(thumbValue);
	};
	#props = /* @__PURE__ */ user_derived(() => ({
		id: this.opts.id.current,
		"data-orientation": this.opts.orientation.current,
		"data-disabled": boolToEmptyStrOrUndef(this.opts.disabled.current),
		style: { touchAction: get(this.#touchAction) },
		[sliderAttrs.root]: "",
		...this.attachment
	}));
	get props() {
		return get(this.#props);
	}
	set props(value) {
		set(this.#props, value);
	}
};
var SliderSingleRootState = class extends SliderBaseRootState {
	opts;
	isMulti = false;
	constructor(opts) {
		super(opts);
		this.opts = opts;
		onMountEffect(() => {
			return executeCallbacks(on(this.domContext.getDocument(), "pointerdown", this.handlePointerDown), on(this.domContext.getDocument(), "pointerup", this.handlePointerUp), on(this.domContext.getDocument(), "pointermove", this.handlePointerMove), on(this.domContext.getDocument(), "pointerleave", this.handlePointerUp));
		});
		watch([
			() => this.opts.step.current,
			() => this.opts.min.current,
			() => this.opts.max.current,
			() => this.opts.value.current
		], ([step, min, max, value]) => {
			const steps = normalizeSteps(step, min, max);
			const isValidValue = (v) => {
				return steps.includes(v);
			};
			const gcv = (v) => {
				return snapValueToCustomSteps(v, steps);
			};
			if (!isValidValue(value)) this.opts.value.current = gcv(value);
		});
	}
	isTickValueSelected = (tickValue) => {
		return this.opts.value.current === tickValue;
	};
	applyPosition({ clientXY, start, end }) {
		const min = this.opts.min.current;
		const max = this.opts.max.current;
		const val = (clientXY - start) / (end - start) * (max - min) + min;
		if (val < min) this.updateValue(min);
		else if (val > max) this.updateValue(max);
		else {
			const steps = this.normalizedSteps;
			const newValue = snapValueToCustomSteps(val, steps);
			this.updateValue(newValue);
		}
	}
	updateValue = (newValue) => {
		this.opts.value.current = snapValueToCustomSteps(newValue, this.normalizedSteps);
	};
	handlePointerMove = (e) => {
		if (!this.isActive || this.opts.disabled.current) return;
		e.preventDefault();
		e.stopPropagation();
		const sliderNode = this.opts.ref.current;
		const activeThumb = this.getAllThumbs()[0];
		if (!sliderNode || !activeThumb) return;
		activeThumb.focus();
		const { left, right, top, bottom } = sliderNode.getBoundingClientRect();
		if (this.direction === "lr") this.applyPosition({
			clientXY: e.clientX,
			start: left,
			end: right
		});
		else if (this.direction === "rl") this.applyPosition({
			clientXY: e.clientX,
			start: right,
			end: left
		});
		else if (this.direction === "bt") this.applyPosition({
			clientXY: e.clientY,
			start: bottom,
			end: top
		});
		else if (this.direction === "tb") this.applyPosition({
			clientXY: e.clientY,
			start: top,
			end: bottom
		});
	};
	handlePointerDown = (e) => {
		if (e.button !== 0 || this.opts.disabled.current) return;
		const sliderNode = this.opts.ref.current;
		const closestThumb = this.getAllThumbs()[0];
		if (!closestThumb || !sliderNode) return;
		const target = e.composedPath()[0] ?? e.target;
		if (!isElementOrSVGElement(target) || !sliderNode.contains(target)) return;
		e.preventDefault();
		closestThumb.focus();
		this.isActive = true;
		this.handlePointerMove(e);
	};
	handlePointerUp = () => {
		if (this.opts.disabled.current) return;
		if (this.isActive) this.opts.onValueCommit.current(untrack(() => this.opts.value.current));
		this.isActive = false;
	};
	#thumbsPropsArr = /* @__PURE__ */ user_derived(() => {
		const currValue = this.opts.value.current;
		return Array.from({ length: 1 }, () => {
			const thumbValue = currValue;
			const thumbPosition = this.getPositionFromValue(thumbValue);
			const style = getThumbStyles(this.direction, thumbPosition);
			return {
				role: "slider",
				"aria-valuemin": this.opts.min.current,
				"aria-valuemax": this.opts.max.current,
				"aria-valuenow": thumbValue,
				"aria-disabled": boolToStr(this.opts.disabled.current),
				"aria-orientation": this.opts.orientation.current,
				"data-value": thumbValue,
				"data-orientation": this.opts.orientation.current,
				style,
				[sliderAttrs.thumb]: ""
			};
		});
	});
	get thumbsPropsArr() {
		return get(this.#thumbsPropsArr);
	}
	set thumbsPropsArr(value) {
		set(this.#thumbsPropsArr, value);
	}
	#thumbsRenderArr = /* @__PURE__ */ user_derived(() => {
		return this.thumbsPropsArr.map((_, i) => i);
	});
	get thumbsRenderArr() {
		return get(this.#thumbsRenderArr);
	}
	set thumbsRenderArr(value) {
		set(this.#thumbsRenderArr, value);
	}
	#ticksPropsArr = /* @__PURE__ */ user_derived(() => {
		const steps = this.normalizedSteps;
		const currValue = this.opts.value.current;
		return steps.map((tickValue, i) => {
			const tickPosition = this.getPositionFromValue(tickValue);
			const isFirst = i === 0;
			const isLast = i === steps.length - 1;
			const offsetPercentage = isFirst ? 0 : isLast ? -100 : -50;
			const style = getTickStyles(this.direction, tickPosition, offsetPercentage);
			const bounded = tickValue <= currValue;
			return {
				"data-disabled": boolToEmptyStrOrUndef(this.opts.disabled.current),
				"data-orientation": this.opts.orientation.current,
				"data-bounded": bounded ? "" : void 0,
				"data-value": tickValue,
				"data-selected": this.isTickValueSelected(tickValue) ? "" : void 0,
				style,
				[sliderAttrs.tick]: ""
			};
		});
	});
	get ticksPropsArr() {
		return get(this.#ticksPropsArr);
	}
	set ticksPropsArr(value) {
		set(this.#ticksPropsArr, value);
	}
	#ticksRenderArr = /* @__PURE__ */ user_derived(() => {
		return this.ticksPropsArr.map((_, i) => i);
	});
	get ticksRenderArr() {
		return get(this.#ticksRenderArr);
	}
	set ticksRenderArr(value) {
		set(this.#ticksRenderArr, value);
	}
	#tickItemsArr = /* @__PURE__ */ user_derived(() => {
		return this.ticksPropsArr.map((tick, i) => ({
			value: tick["data-value"],
			index: i
		}));
	});
	get tickItemsArr() {
		return get(this.#tickItemsArr);
	}
	set tickItemsArr(value) {
		set(this.#tickItemsArr, value);
	}
	#thumbItemsArr = /* @__PURE__ */ user_derived(() => {
		return [{
			value: this.opts.value.current,
			index: 0
		}];
	});
	get thumbItemsArr() {
		return get(this.#thumbItemsArr);
	}
	set thumbItemsArr(value) {
		set(this.#thumbItemsArr, value);
	}
	#snippetProps = /* @__PURE__ */ user_derived(() => ({
		ticks: this.ticksRenderArr,
		thumbs: this.thumbsRenderArr,
		tickItems: this.tickItemsArr,
		thumbItems: this.thumbItemsArr
	}));
	get snippetProps() {
		return get(this.#snippetProps);
	}
	set snippetProps(value) {
		set(this.#snippetProps, value);
	}
};
var SliderMultiRootState = class extends SliderBaseRootState {
	opts;
	isMulti = true;
	#activeThumb = /* @__PURE__ */ state(null);
	get activeThumb() {
		return get(this.#activeThumb);
	}
	set activeThumb(value) {
		set(this.#activeThumb, value, true);
	}
	#currentThumbIdx = /* @__PURE__ */ state(0);
	get currentThumbIdx() {
		return get(this.#currentThumbIdx);
	}
	set currentThumbIdx(value) {
		set(this.#currentThumbIdx, value, true);
	}
	constructor(opts) {
		super(opts);
		this.opts = opts;
		onMountEffect(() => {
			return executeCallbacks(on(this.domContext.getDocument(), "pointerdown", this.handlePointerDown), on(this.domContext.getDocument(), "pointerup", this.handlePointerUp), on(this.domContext.getDocument(), "pointermove", this.handlePointerMove), on(this.domContext.getDocument(), "pointerleave", this.handlePointerUp));
		});
		watch([
			() => this.opts.step.current,
			() => this.opts.min.current,
			() => this.opts.max.current,
			() => this.opts.value.current
		], ([step, min, max, value]) => {
			const steps = normalizeSteps(step, min, max);
			const isValidValue = (v) => {
				return steps.includes(v);
			};
			const gcv = (v) => {
				return snapValueToCustomSteps(v, steps);
			};
			if (value.some((v) => !isValidValue(v))) this.opts.value.current = value.map(gcv);
		});
	}
	isTickValueSelected = (tickValue) => {
		return this.opts.value.current.includes(tickValue);
	};
	isThumbActive(index) {
		return this.isActive && this.activeThumb?.idx === index;
	}
	applyPosition({ clientXY, activeThumbIdx, start, end }) {
		const min = this.opts.min.current;
		const max = this.opts.max.current;
		const val = (clientXY - start) / (end - start) * (max - min) + min;
		if (val < min) this.updateValue(min, activeThumbIdx);
		else if (val > max) this.updateValue(max, activeThumbIdx);
		else {
			const steps = this.normalizedSteps;
			const newValue = snapValueToCustomSteps(val, steps);
			this.updateValue(newValue, activeThumbIdx);
		}
	}
	#getClosestThumb = (e) => {
		const thumbs = this.getAllThumbs();
		if (!thumbs.length) return;
		for (const thumb of thumbs) thumb.blur();
		const distances = thumbs.map((thumb) => {
			if (this.opts.orientation.current === "horizontal") {
				const { left, right } = thumb.getBoundingClientRect();
				return Math.abs(e.clientX - (left + right) / 2);
			} else {
				const { top, bottom } = thumb.getBoundingClientRect();
				return Math.abs(e.clientY - (top + bottom) / 2);
			}
		});
		const node = thumbs[distances.indexOf(Math.min(...distances))];
		return {
			node,
			idx: thumbs.indexOf(node)
		};
	};
	handlePointerMove = (e) => {
		if (!this.isActive || this.opts.disabled.current) return;
		e.preventDefault();
		e.stopPropagation();
		const sliderNode = this.opts.ref.current;
		const activeThumb = this.activeThumb;
		if (!sliderNode || !activeThumb) return;
		activeThumb.node.focus();
		const { left, right, top, bottom } = sliderNode.getBoundingClientRect();
		const direction = this.direction;
		if (direction === "lr") this.applyPosition({
			clientXY: e.clientX,
			activeThumbIdx: activeThumb.idx,
			start: left,
			end: right
		});
		else if (direction === "rl") this.applyPosition({
			clientXY: e.clientX,
			activeThumbIdx: activeThumb.idx,
			start: right,
			end: left
		});
		else if (direction === "bt") this.applyPosition({
			clientXY: e.clientY,
			activeThumbIdx: activeThumb.idx,
			start: bottom,
			end: top
		});
		else if (direction === "tb") this.applyPosition({
			clientXY: e.clientY,
			activeThumbIdx: activeThumb.idx,
			start: top,
			end: bottom
		});
	};
	handlePointerDown = (e) => {
		if (e.button !== 0 || this.opts.disabled.current) return;
		const sliderNode = this.opts.ref.current;
		const closestThumb = this.#getClosestThumb(e);
		if (!closestThumb || !sliderNode) return;
		const target = e.composedPath()[0] ?? e.target;
		if (!isElementOrSVGElement(target) || !sliderNode.contains(target)) return;
		e.preventDefault();
		this.activeThumb = closestThumb;
		closestThumb.node.focus();
		this.isActive = true;
		this.handlePointerMove(e);
	};
	handlePointerUp = () => {
		if (this.opts.disabled.current) return;
		if (this.isActive) this.opts.onValueCommit.current(untrack(() => this.opts.value.current));
		this.isActive = false;
	};
	getAllThumbs = () => {
		const node = this.opts.ref.current;
		if (!node) return [];
		return Array.from(node.querySelectorAll(sliderAttrs.selector("thumb")));
	};
	updateValue = (thumbValue, idx) => {
		const currValue = this.opts.value.current;
		if (!currValue.length) {
			this.opts.value.current.push(thumbValue);
			return;
		}
		if (currValue[idx] === thumbValue) return;
		const newValue = [...currValue];
		if (!isValidIndex(idx, newValue)) return;
		const direction = newValue[idx] > thumbValue ? -1 : 1;
		const swap = () => {
			const diffIndex = idx + direction;
			newValue[idx] = newValue[diffIndex];
			newValue[diffIndex] = thumbValue;
			const thumbs = this.getAllThumbs();
			if (!thumbs.length) return;
			thumbs[diffIndex]?.focus();
			this.activeThumb = {
				node: thumbs[diffIndex],
				idx: diffIndex
			};
		};
		if (this.opts.autoSort.current && (direction === -1 && thumbValue < newValue[idx - 1] || direction === 1 && thumbValue > newValue[idx + 1])) {
			swap();
			this.opts.value.current = newValue;
			return;
		}
		const steps = this.normalizedSteps;
		newValue[idx] = snapValueToCustomSteps(thumbValue, steps);
		this.opts.value.current = newValue;
	};
	#thumbsPropsArr = /* @__PURE__ */ user_derived(() => {
		const currValue = this.opts.value.current;
		return Array.from({ length: currValue.length || 1 }, (_, i) => {
			const currThumb = untrack(() => this.currentThumbIdx);
			if (currThumb < currValue.length) untrack(() => {
				this.currentThumbIdx = currThumb + 1;
			});
			const thumbValue = currValue[i];
			const thumbPosition = this.getPositionFromValue(thumbValue ?? 0);
			const style = getThumbStyles(this.direction, thumbPosition);
			return {
				role: "slider",
				"aria-valuemin": this.opts.min.current,
				"aria-valuemax": this.opts.max.current,
				"aria-valuenow": thumbValue,
				"aria-disabled": boolToStr(this.opts.disabled.current),
				"aria-orientation": this.opts.orientation.current,
				"data-value": thumbValue,
				"data-orientation": this.opts.orientation.current,
				style,
				[sliderAttrs.thumb]: ""
			};
		});
	});
	get thumbsPropsArr() {
		return get(this.#thumbsPropsArr);
	}
	set thumbsPropsArr(value) {
		set(this.#thumbsPropsArr, value);
	}
	#thumbsRenderArr = /* @__PURE__ */ user_derived(() => {
		return this.thumbsPropsArr.map((_, i) => i);
	});
	get thumbsRenderArr() {
		return get(this.#thumbsRenderArr);
	}
	set thumbsRenderArr(value) {
		set(this.#thumbsRenderArr, value);
	}
	#ticksPropsArr = /* @__PURE__ */ user_derived(() => {
		const steps = this.normalizedSteps;
		const currValue = this.opts.value.current;
		return steps.map((tickValue, i) => {
			const tickPosition = this.getPositionFromValue(tickValue);
			const isFirst = i === 0;
			const isLast = i === steps.length - 1;
			const offsetPercentage = isFirst ? 0 : isLast ? -100 : -50;
			const style = getTickStyles(this.direction, tickPosition, offsetPercentage);
			const bounded = currValue.length === 1 ? tickValue <= currValue[0] : currValue[0] <= tickValue && tickValue <= currValue[currValue.length - 1];
			return {
				"data-disabled": boolToEmptyStrOrUndef(this.opts.disabled.current),
				"data-orientation": this.opts.orientation.current,
				"data-bounded": bounded ? "" : void 0,
				"data-value": tickValue,
				style,
				[sliderAttrs.tick]: ""
			};
		});
	});
	get ticksPropsArr() {
		return get(this.#ticksPropsArr);
	}
	set ticksPropsArr(value) {
		set(this.#ticksPropsArr, value);
	}
	#ticksRenderArr = /* @__PURE__ */ user_derived(() => {
		return this.ticksPropsArr.map((_, i) => i);
	});
	get ticksRenderArr() {
		return get(this.#ticksRenderArr);
	}
	set ticksRenderArr(value) {
		set(this.#ticksRenderArr, value);
	}
	#tickItemsArr = /* @__PURE__ */ user_derived(() => {
		return this.ticksPropsArr.map((tick, i) => ({
			value: tick["data-value"],
			index: i
		}));
	});
	get tickItemsArr() {
		return get(this.#tickItemsArr);
	}
	set tickItemsArr(value) {
		set(this.#tickItemsArr, value);
	}
	#thumbItemsArr = /* @__PURE__ */ user_derived(() => {
		return this.opts.value.current.map((value, index) => ({
			value,
			index
		}));
	});
	get thumbItemsArr() {
		return get(this.#thumbItemsArr);
	}
	set thumbItemsArr(value) {
		set(this.#thumbItemsArr, value);
	}
	#snippetProps = /* @__PURE__ */ user_derived(() => ({
		ticks: this.ticksRenderArr,
		thumbs: this.thumbsRenderArr,
		tickItems: this.tickItemsArr,
		thumbItems: this.thumbItemsArr
	}));
	get snippetProps() {
		return get(this.#snippetProps);
	}
	set snippetProps(value) {
		set(this.#snippetProps, value);
	}
};
var SliderRootState = class {
	static create(opts) {
		const { type, ...rest } = opts;
		const rootState = type === "single" ? new SliderSingleRootState(rest) : new SliderMultiRootState(rest);
		return SliderRootContext.set(rootState);
	}
};
var VALID_SLIDER_KEYS = [
	ARROW_LEFT,
	ARROW_RIGHT,
	ARROW_UP,
	ARROW_DOWN,
	HOME,
	"End"
];
var SliderRangeState = class SliderRangeState {
	static create(opts) {
		return new SliderRangeState(opts, SliderRootContext.get());
	}
	opts;
	root;
	attachment;
	constructor(opts, root) {
		this.opts = opts;
		this.root = root;
		this.attachment = attachRef(opts.ref);
	}
	#rangeStyles = /* @__PURE__ */ user_derived(() => {
		if (Array.isArray(this.root.opts.value.current)) {
			const min = this.root.opts.value.current.length > 1 ? this.root.getPositionFromValue(Math.min(...this.root.opts.value.current) ?? 0) : 0;
			const max = 100 - this.root.getPositionFromValue(Math.max(...this.root.opts.value.current) ?? 0);
			return {
				position: "absolute",
				...getRangeStyles(this.root.direction, min, max)
			};
		} else {
			const trackPadding = this.root.opts.trackPadding?.current;
			const currentValue = this.root.opts.value.current;
			const maxValue = this.root.opts.max.current;
			const min = 0;
			const max = trackPadding !== void 0 && trackPadding > 0 && currentValue === maxValue ? 0 : 100 - this.root.getPositionFromValue(currentValue);
			return {
				position: "absolute",
				...getRangeStyles(this.root.direction, min, max)
			};
		}
	});
	get rangeStyles() {
		return get(this.#rangeStyles);
	}
	set rangeStyles(value) {
		set(this.#rangeStyles, value);
	}
	#props = /* @__PURE__ */ user_derived(() => ({
		id: this.opts.id.current,
		"data-orientation": this.root.opts.orientation.current,
		"data-disabled": boolToEmptyStrOrUndef(this.root.opts.disabled.current),
		style: this.rangeStyles,
		[sliderAttrs.range]: "",
		...this.attachment
	}));
	get props() {
		return get(this.#props);
	}
	set props(value) {
		set(this.#props, value);
	}
};
var SliderThumbState = class SliderThumbState {
	static create(opts) {
		return new SliderThumbState(opts, SliderRootContext.get());
	}
	opts;
	root;
	attachment;
	#isDisabled = /* @__PURE__ */ user_derived(() => this.root.opts.disabled.current || this.opts.disabled.current);
	constructor(opts, root) {
		this.opts = opts;
		this.root = root;
		this.attachment = attachRef(opts.ref);
		this.onkeydown = this.onkeydown.bind(this);
	}
	#updateValue(newValue) {
		if (this.root.isMulti) this.root.updateValue(newValue, this.opts.index.current);
		else this.root.updateValue(newValue);
	}
	onkeydown(e) {
		if (get(this.#isDisabled)) return;
		const currNode = this.opts.ref.current;
		if (!currNode) return;
		const thumbs = this.root.getAllThumbs();
		if (!thumbs.length) return;
		const idx = thumbs.indexOf(currNode);
		if (this.root.isMulti) this.root.currentThumbIdx = idx;
		if (!VALID_SLIDER_KEYS.includes(e.key)) return;
		e.preventDefault();
		const min = this.root.opts.min.current;
		const max = this.root.opts.max.current;
		const value = this.root.opts.value.current;
		const thumbValue = Array.isArray(value) ? value[idx] : value;
		const orientation = this.root.opts.orientation.current;
		const direction = this.root.direction;
		const steps = this.root.normalizedSteps;
		switch (e.key) {
			case HOME:
				this.#updateValue(min);
				break;
			case "End":
				this.#updateValue(max);
				break;
			case ARROW_LEFT:
				if (orientation !== "horizontal") break;
				if (e.metaKey) {
					const newValue = direction === "rl" ? max : min;
					this.#updateValue(newValue);
				} else {
					const newValue = getAdjacentStepValue(thumbValue, steps, direction === "rl" ? "next" : "prev");
					this.#updateValue(newValue);
				}
				break;
			case ARROW_RIGHT:
				if (orientation !== "horizontal") break;
				if (e.metaKey) {
					const newValue = direction === "rl" ? min : max;
					this.#updateValue(newValue);
				} else {
					const newValue = getAdjacentStepValue(thumbValue, steps, direction === "rl" ? "prev" : "next");
					this.#updateValue(newValue);
				}
				break;
			case ARROW_UP:
				if (e.metaKey) {
					const newValue = direction === "tb" ? min : max;
					this.#updateValue(newValue);
				} else {
					const newValue = getAdjacentStepValue(thumbValue, steps, direction === "tb" ? "prev" : "next");
					this.#updateValue(newValue);
				}
				break;
			case ARROW_DOWN:
				if (e.metaKey) {
					const newValue = direction === "tb" ? max : min;
					this.#updateValue(newValue);
				} else {
					const newValue = getAdjacentStepValue(thumbValue, steps, direction === "tb" ? "next" : "prev");
					this.#updateValue(newValue);
				}
				break;
		}
		this.root.opts.onValueCommit.current(this.root.opts.value.current);
	}
	#props = /* @__PURE__ */ user_derived(() => ({
		...this.root.thumbsPropsArr[this.opts.index.current],
		id: this.opts.id.current,
		onkeydown: this.onkeydown,
		"data-active": this.root.isThumbActive(this.opts.index.current) ? "" : void 0,
		"data-disabled": boolToEmptyStrOrUndef(this.opts.disabled.current || this.root.opts.disabled.current),
		tabindex: this.opts.disabled.current || this.root.opts.disabled.current ? -1 : 0,
		...this.attachment
	}));
	get props() {
		return get(this.#props);
	}
	set props(value) {
		set(this.#props, value);
	}
};
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/slider/components/slider.svelte
var root_2$5 = /* @__PURE__ */ from_html(`<span><!></span>`);
function Slider($$anchor, $$props) {
	const uid = props_id();
	push($$props, true);
	let id = prop($$props, "id", 19, () => createId(uid)), ref = prop($$props, "ref", 15, null), value = prop($$props, "value", 15), onValueChange = prop($$props, "onValueChange", 3, noop), onValueCommit = prop($$props, "onValueCommit", 3, noop), disabled = prop($$props, "disabled", 3, false), step = prop($$props, "step", 3, 1), dir = prop($$props, "dir", 3, "ltr"), autoSort = prop($$props, "autoSort", 3, true), orientation = prop($$props, "orientation", 3, "horizontal"), thumbPositioning = prop($$props, "thumbPositioning", 3, "contain"), restProps = /* @__PURE__ */ rest_props($$props, [
		"$$slots",
		"$$events",
		"$$legacy",
		"children",
		"child",
		"id",
		"ref",
		"value",
		"type",
		"onValueChange",
		"onValueCommit",
		"disabled",
		"min",
		"max",
		"step",
		"dir",
		"autoSort",
		"orientation",
		"thumbPositioning",
		"trackPadding"
	]);
	const min = /* @__PURE__ */ user_derived(() => {
		if ($$props.min !== void 0) return $$props.min;
		if (Array.isArray(step())) return Math.min(...step());
		return 0;
	});
	const max = /* @__PURE__ */ user_derived(() => {
		if ($$props.max !== void 0) return $$props.max;
		if (Array.isArray(step())) return Math.max(...step());
		return 100;
	});
	function handleDefaultValue() {
		if (value() !== void 0) return;
		if ($$props.type === "single") return get(min);
		return [];
	}
	handleDefaultValue();
	watch.pre(() => value(), () => {
		handleDefaultValue();
	});
	const rootState = SliderRootState.create({
		id: boxWith(() => id()),
		ref: boxWith(() => ref(), (v) => ref(v)),
		value: boxWith(() => value(), (v) => {
			value(v);
			onValueChange()(v);
		}),
		onValueCommit: boxWith(() => onValueCommit()),
		disabled: boxWith(() => disabled()),
		min: boxWith(() => get(min)),
		max: boxWith(() => get(max)),
		step: boxWith(() => step()),
		dir: boxWith(() => dir()),
		autoSort: boxWith(() => autoSort()),
		orientation: boxWith(() => orientation()),
		thumbPositioning: boxWith(() => thumbPositioning()),
		type: $$props.type,
		trackPadding: boxWith(() => $$props.trackPadding)
	});
	const mergedProps = /* @__PURE__ */ user_derived(() => mergeProps(restProps, rootState.props));
	var fragment = comment();
	var node = first_child(fragment);
	var consequent = ($$anchor) => {
		var fragment_1 = comment();
		var node_1 = first_child(fragment_1);
		{
			let $0 = /* @__PURE__ */ user_derived(() => ({
				props: get(mergedProps),
				...rootState.snippetProps
			}));
			snippet(node_1, () => $$props.child, () => get($0));
		}
		append($$anchor, fragment_1);
	};
	var alternate = ($$anchor) => {
		var span = root_2$5();
		attribute_effect(span, () => ({ ...get(mergedProps) }));
		snippet(child(span), () => $$props.children ?? noop$1, () => rootState.snippetProps);
		reset(span);
		append($$anchor, span);
	};
	if_block(node, ($$render) => {
		if ($$props.child) $$render(consequent);
		else $$render(alternate, -1);
	});
	append($$anchor, fragment);
	pop();
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/slider/components/slider-range.svelte
var root_2$4 = /* @__PURE__ */ from_html(`<span><!></span>`);
function Slider_range($$anchor, $$props) {
	const uid = props_id();
	push($$props, true);
	let ref = prop($$props, "ref", 15, null), id = prop($$props, "id", 19, () => createId(uid)), restProps = /* @__PURE__ */ rest_props($$props, [
		"$$slots",
		"$$events",
		"$$legacy",
		"children",
		"child",
		"ref",
		"id"
	]);
	const rangeState = SliderRangeState.create({
		id: boxWith(() => id()),
		ref: boxWith(() => ref(), (v) => ref(v))
	});
	const mergedProps = /* @__PURE__ */ user_derived(() => mergeProps(restProps, rangeState.props));
	var fragment = comment();
	var node = first_child(fragment);
	var consequent = ($$anchor) => {
		var fragment_1 = comment();
		snippet(first_child(fragment_1), () => $$props.child, () => ({ props: get(mergedProps) }));
		append($$anchor, fragment_1);
	};
	var alternate = ($$anchor) => {
		var span = root_2$4();
		attribute_effect(span, () => ({ ...get(mergedProps) }));
		snippet(child(span), () => $$props.children ?? noop$1);
		reset(span);
		append($$anchor, span);
	};
	if_block(node, ($$render) => {
		if ($$props.child) $$render(consequent);
		else $$render(alternate, -1);
	});
	append($$anchor, fragment);
	pop();
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/slider/components/slider-thumb.svelte
var root_2$3 = /* @__PURE__ */ from_html(`<span><!></span>`);
function Slider_thumb($$anchor, $$props) {
	const uid = props_id();
	push($$props, true);
	let ref = prop($$props, "ref", 15, null), id = prop($$props, "id", 19, () => createId(uid)), disabled = prop($$props, "disabled", 3, false), restProps = /* @__PURE__ */ rest_props($$props, [
		"$$slots",
		"$$events",
		"$$legacy",
		"children",
		"child",
		"ref",
		"id",
		"index",
		"disabled"
	]);
	const thumbState = SliderThumbState.create({
		id: boxWith(() => id()),
		ref: boxWith(() => ref(), (v) => ref(v)),
		index: boxWith(() => $$props.index),
		disabled: boxWith(() => disabled())
	});
	const mergedProps = /* @__PURE__ */ user_derived(() => mergeProps(restProps, thumbState.props));
	var fragment = comment();
	var node = first_child(fragment);
	var consequent = ($$anchor) => {
		var fragment_1 = comment();
		var node_1 = first_child(fragment_1);
		{
			let $0 = /* @__PURE__ */ user_derived(() => ({
				active: thumbState.root.isThumbActive(thumbState.opts.index.current),
				props: get(mergedProps)
			}));
			snippet(node_1, () => $$props.child, () => get($0));
		}
		append($$anchor, fragment_1);
	};
	var alternate = ($$anchor) => {
		var span = root_2$3();
		attribute_effect(span, () => ({ ...get(mergedProps) }));
		var node_2 = child(span);
		{
			let $0 = /* @__PURE__ */ user_derived(() => ({ active: thumbState.root.isThumbActive(thumbState.opts.index.current) }));
			snippet(node_2, () => $$props.children ?? noop$1, () => get($0));
		}
		reset(span);
		append($$anchor, span);
	};
	if_block(node, ($$render) => {
		if ($$props.child) $$render(consequent);
		else $$render(alternate, -1);
	});
	append($$anchor, fragment);
	pop();
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/switch/switch.svelte.js
var switchAttrs = createBitsAttrs({
	component: "switch",
	parts: ["root", "thumb"]
});
var SwitchRootContext = new Context("Switch.Root");
var SwitchRootState = class SwitchRootState {
	static create(opts) {
		return SwitchRootContext.set(new SwitchRootState(opts));
	}
	opts;
	attachment;
	constructor(opts) {
		this.opts = opts;
		this.attachment = attachRef(opts.ref);
		this.onkeydown = this.onkeydown.bind(this);
		this.onclick = this.onclick.bind(this);
	}
	#toggle() {
		this.opts.checked.current = !this.opts.checked.current;
	}
	onkeydown(e) {
		if (!(e.key === "Enter" || e.key === " ") || this.opts.disabled.current) return;
		e.preventDefault();
		this.#toggle();
	}
	onclick(_) {
		if (this.opts.disabled.current) return;
		this.#toggle();
	}
	#sharedProps = /* @__PURE__ */ user_derived(() => ({
		"data-disabled": boolToEmptyStrOrUndef(this.opts.disabled.current),
		"data-state": getDataChecked(this.opts.checked.current),
		"data-required": boolToEmptyStrOrUndef(this.opts.required.current)
	}));
	get sharedProps() {
		return get(this.#sharedProps);
	}
	set sharedProps(value) {
		set(this.#sharedProps, value);
	}
	#snippetProps = /* @__PURE__ */ user_derived(() => ({ checked: this.opts.checked.current }));
	get snippetProps() {
		return get(this.#snippetProps);
	}
	set snippetProps(value) {
		set(this.#snippetProps, value);
	}
	#props = /* @__PURE__ */ user_derived(() => ({
		...this.sharedProps,
		id: this.opts.id.current,
		role: "switch",
		disabled: boolToTrueOrUndef(this.opts.disabled.current),
		"aria-checked": getAriaChecked(this.opts.checked.current, false),
		"aria-required": boolToStr(this.opts.required.current),
		[switchAttrs.root]: "",
		onclick: this.onclick,
		onkeydown: this.onkeydown,
		...this.attachment
	}));
	get props() {
		return get(this.#props);
	}
	set props(value) {
		set(this.#props, value);
	}
};
var SwitchInputState = class SwitchInputState {
	static create() {
		return new SwitchInputState(SwitchRootContext.get());
	}
	root;
	#shouldRender = /* @__PURE__ */ user_derived(() => this.root.opts.name.current !== void 0);
	get shouldRender() {
		return get(this.#shouldRender);
	}
	set shouldRender(value) {
		set(this.#shouldRender, value);
	}
	constructor(root) {
		this.root = root;
	}
	#props = /* @__PURE__ */ user_derived(() => ({
		type: "checkbox",
		name: this.root.opts.name.current,
		value: this.root.opts.value.current,
		checked: this.root.opts.checked.current,
		disabled: this.root.opts.disabled.current,
		required: this.root.opts.required.current
	}));
	get props() {
		return get(this.#props);
	}
	set props(value) {
		set(this.#props, value);
	}
};
var SwitchThumbState = class SwitchThumbState {
	static create(opts) {
		return new SwitchThumbState(opts, SwitchRootContext.get());
	}
	opts;
	root;
	attachment;
	constructor(opts, root) {
		this.opts = opts;
		this.root = root;
		this.attachment = attachRef(opts.ref);
	}
	#snippetProps = /* @__PURE__ */ user_derived(() => ({ checked: this.root.opts.checked.current }));
	get snippetProps() {
		return get(this.#snippetProps);
	}
	set snippetProps(value) {
		set(this.#snippetProps, value);
	}
	#props = /* @__PURE__ */ user_derived(() => ({
		...this.root.sharedProps,
		id: this.opts.id.current,
		[switchAttrs.thumb]: "",
		...this.attachment
	}));
	get props() {
		return get(this.#props);
	}
	set props(value) {
		set(this.#props, value);
	}
};
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/switch/components/switch-input.svelte
function Switch_input($$anchor, $$props) {
	push($$props, false);
	const inputState = SwitchInputState.create();
	init();
	var fragment = comment();
	var node = first_child(fragment);
	var consequent = ($$anchor) => {
		Hidden_input($$anchor, spread_props(() => inputState.props));
	};
	if_block(node, ($$render) => {
		if (inputState.shouldRender) $$render(consequent);
	});
	append($$anchor, fragment);
	pop();
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/switch/components/switch.svelte
var root_2$2 = /* @__PURE__ */ from_html(`<button><!></button>`);
var root$2 = /* @__PURE__ */ from_html(`<!> <!>`, 1);
function Switch($$anchor, $$props) {
	const uid = props_id();
	push($$props, true);
	let ref = prop($$props, "ref", 15, null), id = prop($$props, "id", 19, () => createId(uid)), disabled = prop($$props, "disabled", 3, false), required = prop($$props, "required", 3, false), checked = prop($$props, "checked", 15, false), value = prop($$props, "value", 3, "on"), name = prop($$props, "name", 3, void 0), type = prop($$props, "type", 3, "button"), onCheckedChange = prop($$props, "onCheckedChange", 3, noop), restProps = /* @__PURE__ */ rest_props($$props, [
		"$$slots",
		"$$events",
		"$$legacy",
		"child",
		"children",
		"ref",
		"id",
		"disabled",
		"required",
		"checked",
		"value",
		"name",
		"type",
		"onCheckedChange"
	]);
	const rootState = SwitchRootState.create({
		checked: boxWith(() => checked(), (v) => {
			checked(v);
			onCheckedChange()?.(v);
		}),
		disabled: boxWith(() => disabled() ?? false),
		required: boxWith(() => required()),
		value: boxWith(() => value()),
		name: boxWith(() => name()),
		id: boxWith(() => id()),
		ref: boxWith(() => ref(), (v) => ref(v))
	});
	const mergedProps = /* @__PURE__ */ user_derived(() => mergeProps(restProps, rootState.props, { type: type() }));
	var fragment = root$2();
	var node = first_child(fragment);
	var consequent = ($$anchor) => {
		var fragment_1 = comment();
		var node_1 = first_child(fragment_1);
		{
			let $0 = /* @__PURE__ */ user_derived(() => ({
				props: get(mergedProps),
				...rootState.snippetProps
			}));
			snippet(node_1, () => $$props.child, () => get($0));
		}
		append($$anchor, fragment_1);
	};
	var alternate = ($$anchor) => {
		var button = root_2$2();
		attribute_effect(button, () => ({ ...get(mergedProps) }));
		snippet(child(button), () => $$props.children ?? noop$1, () => rootState.snippetProps);
		reset(button);
		append($$anchor, button);
	};
	if_block(node, ($$render) => {
		if ($$props.child) $$render(consequent);
		else $$render(alternate, -1);
	});
	Switch_input(sibling(node, 2), {});
	append($$anchor, fragment);
	pop();
}
//#endregion
//#region node_modules/.pnpm/bits-ui@2.18.1_@internationalized+date@3.12.1_svelte@5.55.7/node_modules/bits-ui/dist/bits/switch/components/switch-thumb.svelte
var root_2$1 = /* @__PURE__ */ from_html(`<span><!></span>`);
function Switch_thumb($$anchor, $$props) {
	const uid = props_id();
	push($$props, true);
	let ref = prop($$props, "ref", 15, null), id = prop($$props, "id", 19, () => createId(uid)), restProps = /* @__PURE__ */ rest_props($$props, [
		"$$slots",
		"$$events",
		"$$legacy",
		"child",
		"children",
		"ref",
		"id"
	]);
	const thumbState = SwitchThumbState.create({
		id: boxWith(() => id()),
		ref: boxWith(() => ref(), (v) => ref(v))
	});
	const mergedProps = /* @__PURE__ */ user_derived(() => mergeProps(restProps, thumbState.props));
	var fragment = comment();
	var node = first_child(fragment);
	var consequent = ($$anchor) => {
		var fragment_1 = comment();
		var node_1 = first_child(fragment_1);
		{
			let $0 = /* @__PURE__ */ user_derived(() => ({
				props: get(mergedProps),
				...thumbState.snippetProps
			}));
			snippet(node_1, () => $$props.child, () => get($0));
		}
		append($$anchor, fragment_1);
	};
	var alternate = ($$anchor) => {
		var span = root_2$1();
		attribute_effect(span, () => ({ ...get(mergedProps) }));
		snippet(child(span), () => $$props.children ?? noop$1, () => thumbState.snippetProps);
		reset(span);
		append($$anchor, span);
	};
	if_block(node, ($$render) => {
		if ($$props.child) $$render(consequent);
		else $$render(alternate, -1);
	});
	append($$anchor, fragment);
	pop();
}
//#endregion
//#region demo/src/RangeNumber.svelte
var root_1 = /* @__PURE__ */ from_html(`<!> <!>`, 1);
var root$1 = /* @__PURE__ */ from_html(`<div class="range-number svelte-1f25k3p"><label class="value-row svelte-1f25k3p"><span> </span> <input type="number" class="svelte-1f25k3p"/></label> <!></div>`);
function RangeNumber($$anchor, $$props) {
	let label = prop($$props, "label", 8);
	let value = prop($$props, "value", 12);
	let min = prop($$props, "min", 8, 0);
	let max = prop($$props, "max", 8, 100);
	let step = prop($$props, "step", 8, 1);
	function clamp(value) {
		return Math.min(Math.max(value, min()), max());
	}
	function selectNumber(event) {
		const input = event.currentTarget;
		if (input instanceof HTMLInputElement) input.select();
	}
	function syncNumber(event) {
		const input = event.currentTarget;
		if (input instanceof HTMLInputElement && !Number.isNaN(input.valueAsNumber)) value(clamp(input.valueAsNumber));
	}
	var div = root$1();
	var label_1 = child(div);
	var span = child(label_1);
	var text = child(span, true);
	reset(span);
	var input_1 = sibling(span, 2);
	remove_input_defaults(input_1);
	reset(label_1);
	Slider(sibling(label_1, 2), {
		class: "slider-root",
		type: "single",
		get min() {
			return min();
		},
		get max() {
			return max();
		},
		get step() {
			return step();
		},
		onValueChange: (nextValue) => value(clamp(nextValue)),
		onValueCommit: (nextValue) => value(clamp(nextValue)),
		get value() {
			return value();
		},
		set value($$value) {
			value($$value);
		},
		children: ($$anchor, $$slotProps) => {
			var fragment = root_1();
			var node_1 = first_child(fragment);
			Slider_range(node_1, { class: "slider-range" });
			Slider_thumb(sibling(node_1, 2), {
				class: "slider-thumb",
				index: 0
			});
			append($$anchor, fragment);
		},
		$$slots: { default: true },
		$$legacy: true
	});
	reset(div);
	template_effect(() => {
		set_text(text, label());
		set_attribute(input_1, "min", min());
		set_attribute(input_1, "max", max());
		set_attribute(input_1, "step", step());
		set_value(input_1, value());
	});
	event("focus", input_1, selectNumber);
	delegated("input", input_1, syncNumber);
	append($$anchor, div);
}
delegate(["input"]);
//#endregion
//#region demo/src/processing-path.ts
var defaultDemoState = {
	signature: "_",
	source: "images/dog.jpg",
	resizeEnabled: true,
	resizeMode: "fill",
	width: 640,
	height: 360,
	gravity: "ce",
	enlarge: false,
	cropEnabled: false,
	cropWidth: 640,
	cropHeight: 420,
	format: "auto",
	quality: 85
};
function optionSegments(currentState) {
	const segments = [];
	if (currentState.cropEnabled) segments.push(`c:${currentState.cropWidth}:${currentState.cropHeight}`);
	if (currentState.resizeEnabled) segments.push([
		"rs",
		currentState.resizeMode,
		currentState.width,
		currentState.height,
		currentState.enlarge ? 1 : 0
	].join(":"), `g:${currentState.gravity}`);
	if (currentState.format !== "auto") segments.push(`f:${currentState.format}`);
	if (currentState.quality > 0) segments.push(`q:${currentState.quality}`);
	return segments;
}
function resolvedOutputLabel(currentState) {
	if (currentState.format === "auto") return "auto -> webp";
	return currentState.format;
}
function processedSizeLabel(metadata) {
	if (metadata === null) return "Loading";
	const dimensions = `${metadata.width} × ${metadata.height}`;
	if (metadata.bytes === null) return dimensions;
	return `${dimensions} (${Math.max(1, Math.round(metadata.bytes / 1024))} kB)`;
}
function buildProcessingPath(currentState) {
	const options = optionSegments(currentState).join("/");
	return `/${currentState.signature}/${options}/plain/${currentState.source}`;
}
//#endregion
//#region demo/src/App.svelte
var root_2 = /* @__PURE__ */ from_html(`<!> <!> <div class="field-grid svelte-1cfu4yu"><label class="field svelte-1cfu4yu"><span class="svelte-1cfu4yu">Type</span> <select class="svelte-1cfu4yu"><option>fit</option><option>fill</option><option>fill-down</option><option>force</option><option>auto</option></select></label> <label class="field svelte-1cfu4yu"><span class="svelte-1cfu4yu">Gravity</span> <select class="svelte-1cfu4yu"><option>center</option><option>north</option><option>south</option><option>east</option><option>west</option><option>north east</option><option>north west</option><option>south east</option><option>south west</option></select></label></div> <label class="switch-field svelte-1cfu4yu"><!> <span>Allow enlargement</span></label>`, 1);
var root_5 = /* @__PURE__ */ from_html(`<!> <!>`, 1);
var root = /* @__PURE__ */ from_html(`<main class="fiddle-shell svelte-1cfu4yu"><button type="button" aria-label="Close tools"></button> <aside aria-label="Processing controls"><div class="drawer-topbar svelte-1cfu4yu"><strong class="svelte-1cfu4yu">Tools</strong> <button class="icon-button svelte-1cfu4yu" type="button" aria-label="Close tools">×</button></div> <div class="tool-stack svelte-1cfu4yu"><section class="tool-section svelte-1cfu4yu"><div class="tool-heading svelte-1cfu4yu"><div><h2 class="svelte-1cfu4yu">Resize</h2> <p class="svelte-1cfu4yu"> </p></div> <!></div> <!></section> <section class="tool-section svelte-1cfu4yu"><div class="tool-heading svelte-1cfu4yu"><div><h2 class="svelte-1cfu4yu">Crop</h2> <p class="svelte-1cfu4yu"> </p></div> <!></div> <!></section> <section class="tool-section svelte-1cfu4yu"><div class="tool-heading svelte-1cfu4yu"><h2 class="svelte-1cfu4yu">Output</h2></div> <label class="field svelte-1cfu4yu"><span class="svelte-1cfu4yu">Format</span> <select class="svelte-1cfu4yu"><option>auto</option><option>webp</option><option>avif</option><option>jpeg</option><option>png</option></select></label> <!></section> <section class="tool-section svelte-1cfu4yu"><div class="tool-heading svelte-1cfu4yu"><h2 class="svelte-1cfu4yu">Request</h2></div> <label class="field svelte-1cfu4yu"><span class="svelte-1cfu4yu">Source image</span> <select class="svelte-1cfu4yu"><option>dog.jpg</option><option>cat-300.jpg</option></select></label> <label class="field svelte-1cfu4yu"><span class="svelte-1cfu4yu">Signature</span> <select class="svelte-1cfu4yu"><option>unsigned</option><option>unsafe</option></select></label></section></div> <div class="drawer-actions svelte-1cfu4yu"><button class="copy-button svelte-1cfu4yu" type="button"> </button> <a class="open-link svelte-1cfu4yu" target="_blank" rel="noreferrer">Open</a></div></aside> <section class="preview-workspace svelte-1cfu4yu" aria-label="Processed image preview"><header class="preview-command-bar svelte-1cfu4yu"><button class="icon-button menu-button svelte-1cfu4yu" type="button" aria-label="Open tools">☰</button> <code class="parameter-preview svelte-1cfu4yu"> </code> <div class="desktop-actions svelte-1cfu4yu"><button class="copy-button copy-button-secondary svelte-1cfu4yu" type="button"> </button> <a class="open-link svelte-1cfu4yu" target="_blank" rel="noreferrer">Open</a></div></header> <div class="preview-canvas svelte-1cfu4yu"><div class="image-frame svelte-1cfu4yu"><figure class="svelte-1cfu4yu"><img alt="Processed sample source" class="svelte-1cfu4yu"/> <figcaption class="svelte-1cfu4yu"><span> </span> <span> </span></figcaption></figure></div></div></section></main>`);
function App($$anchor, $$props) {
	push($$props, false);
	const path = /* @__PURE__ */ mutable_source();
	const previewParameters = /* @__PURE__ */ mutable_source();
	const outputLabel = /* @__PURE__ */ mutable_source();
	const sizeLabel = /* @__PURE__ */ mutable_source();
	let copyLabel = /* @__PURE__ */ mutable_source("Copy URL");
	let drawerOpen = /* @__PURE__ */ mutable_source(false);
	let state = /* @__PURE__ */ mutable_source({ ...defaultDemoState });
	let processedMetadata = /* @__PURE__ */ mutable_source(null);
	let metadataRequestId = 0;
	async function updateProcessedMetadata(event) {
		const image = event.currentTarget;
		if (!(image instanceof HTMLImageElement)) return;
		const requestId = ++metadataRequestId;
		const imagePath = image.currentSrc || image.src;
		const dimensions = {
			width: image.naturalWidth,
			height: image.naturalHeight
		};
		set(processedMetadata, {
			...dimensions,
			bytes: null
		});
		try {
			const blob = await (await fetch(imagePath, { cache: "force-cache" })).blob();
			if (requestId === metadataRequestId) set(processedMetadata, {
				...dimensions,
				bytes: blob.size
			});
		} catch {
			if (requestId === metadataRequestId) set(processedMetadata, {
				...dimensions,
				bytes: null
			});
		}
	}
	async function copyGeneratedUrl() {
		const absoluteUrl = new URL(get(path), window.location.origin).toString();
		await navigator.clipboard.writeText(absoluteUrl);
		set(copyLabel, "Copied");
		window.setTimeout(() => {
			set(copyLabel, "Copy URL");
		}, 1200);
	}
	function copyUrl() {
		copyGeneratedUrl().catch(() => {
			set(copyLabel, "Copy failed");
		});
	}
	legacy_pre_effect(() => get(state), () => {
		set(path, buildProcessingPath(get(state)));
	});
	legacy_pre_effect(() => get(path), () => {
		set(previewParameters, get(path).replace(/^\/(?:_|unsafe)\//, ""));
	});
	legacy_pre_effect(() => get(state), () => {
		set(outputLabel, resolvedOutputLabel(get(state)));
	});
	legacy_pre_effect(() => get(processedMetadata), () => {
		set(sizeLabel, processedSizeLabel(get(processedMetadata)));
	});
	legacy_pre_effect_reset();
	init();
	var main = root();
	var button = child(main);
	let classes;
	var aside = sibling(button, 2);
	let classes_1;
	var div = child(aside);
	var button_1 = sibling(child(div), 2);
	reset(div);
	var div_1 = sibling(div, 2);
	var section = child(div_1);
	var div_2 = child(section);
	var div_3 = child(div_2);
	var p = sibling(child(div_3), 2);
	var text = child(p, true);
	reset(p);
	reset(div_3);
	Switch(sibling(div_3, 2), {
		class: "switch-root",
		"aria-label": "Enable resize",
		get checked() {
			return get(state).resizeEnabled;
		},
		set checked($$value) {
			mutate(state, get(state).resizeEnabled = $$value);
		},
		children: ($$anchor, $$slotProps) => {
			Switch_thumb($$anchor, { class: "switch-thumb" });
		},
		$$slots: { default: true },
		$$legacy: true
	});
	reset(div_2);
	var node_1 = sibling(div_2, 2);
	var consequent = ($$anchor) => {
		var fragment_1 = root_2();
		var node_2 = first_child(fragment_1);
		RangeNumber(node_2, {
			label: "Width",
			min: 0,
			max: 1600,
			step: 1,
			get value() {
				return get(state).width;
			},
			set value($$value) {
				mutate(state, get(state).width = $$value);
			},
			$$legacy: true
		});
		var node_3 = sibling(node_2, 2);
		RangeNumber(node_3, {
			label: "Height",
			min: 0,
			max: 1e3,
			step: 1,
			get value() {
				return get(state).height;
			},
			set value($$value) {
				mutate(state, get(state).height = $$value);
			},
			$$legacy: true
		});
		var div_4 = sibling(node_3, 2);
		var label = child(div_4);
		var select = sibling(child(label), 2);
		var option = child(select);
		option.value = option.__value = "fit";
		var option_1 = sibling(option);
		option_1.value = option_1.__value = "fill";
		var option_2 = sibling(option_1);
		option_2.value = option_2.__value = "fill-down";
		var option_3 = sibling(option_2);
		option_3.value = option_3.__value = "force";
		var option_4 = sibling(option_3);
		option_4.value = option_4.__value = "auto";
		reset(select);
		reset(label);
		var label_1 = sibling(label, 2);
		var select_1 = sibling(child(label_1), 2);
		var option_5 = child(select_1);
		option_5.value = option_5.__value = "ce";
		var option_6 = sibling(option_5);
		option_6.value = option_6.__value = "no";
		var option_7 = sibling(option_6);
		option_7.value = option_7.__value = "so";
		var option_8 = sibling(option_7);
		option_8.value = option_8.__value = "ea";
		var option_9 = sibling(option_8);
		option_9.value = option_9.__value = "we";
		var option_10 = sibling(option_9);
		option_10.value = option_10.__value = "noea";
		var option_11 = sibling(option_10);
		option_11.value = option_11.__value = "nowe";
		var option_12 = sibling(option_11);
		option_12.value = option_12.__value = "soea";
		var option_13 = sibling(option_12);
		option_13.value = option_13.__value = "sowe";
		reset(select_1);
		reset(label_1);
		reset(div_4);
		var label_2 = sibling(div_4, 2);
		Switch(child(label_2), {
			class: "switch-root",
			get checked() {
				return get(state).enlarge;
			},
			set checked($$value) {
				mutate(state, get(state).enlarge = $$value);
			},
			children: ($$anchor, $$slotProps) => {
				Switch_thumb($$anchor, { class: "switch-thumb" });
			},
			$$slots: { default: true },
			$$legacy: true
		});
		next(2);
		reset(label_2);
		bind_select_value(select, () => get(state).resizeMode, ($$value) => mutate(state, get(state).resizeMode = $$value));
		bind_select_value(select_1, () => get(state).gravity, ($$value) => mutate(state, get(state).gravity = $$value));
		append($$anchor, fragment_1);
	};
	if_block(node_1, ($$render) => {
		if (get(state), untrack(() => get(state).resizeEnabled)) $$render(consequent);
	});
	reset(section);
	var section_1 = sibling(section, 2);
	var div_5 = child(section_1);
	var div_6 = child(div_5);
	var p_1 = sibling(child(div_6), 2);
	var text_1 = child(p_1, true);
	reset(p_1);
	reset(div_6);
	Switch(sibling(div_6, 2), {
		class: "switch-root",
		"aria-label": "Enable crop",
		get checked() {
			return get(state).cropEnabled;
		},
		set checked($$value) {
			mutate(state, get(state).cropEnabled = $$value);
		},
		children: ($$anchor, $$slotProps) => {
			Switch_thumb($$anchor, { class: "switch-thumb" });
		},
		$$slots: { default: true },
		$$legacy: true
	});
	reset(div_5);
	var node_6 = sibling(div_5, 2);
	var consequent_1 = ($$anchor) => {
		var fragment_4 = root_5();
		var node_7 = first_child(fragment_4);
		RangeNumber(node_7, {
			label: "Crop width",
			min: 80,
			max: 1200,
			step: 1,
			get value() {
				return get(state).cropWidth;
			},
			set value($$value) {
				mutate(state, get(state).cropWidth = $$value);
			},
			$$legacy: true
		});
		RangeNumber(sibling(node_7, 2), {
			label: "Crop height",
			min: 80,
			max: 900,
			step: 1,
			get value() {
				return get(state).cropHeight;
			},
			set value($$value) {
				mutate(state, get(state).cropHeight = $$value);
			},
			$$legacy: true
		});
		append($$anchor, fragment_4);
	};
	if_block(node_6, ($$render) => {
		if (get(state), untrack(() => get(state).cropEnabled)) $$render(consequent_1);
	});
	reset(section_1);
	var section_2 = sibling(section_1, 2);
	var label_3 = sibling(child(section_2), 2);
	var select_2 = sibling(child(label_3), 2);
	var option_14 = child(select_2);
	option_14.value = option_14.__value = "auto";
	var option_15 = sibling(option_14);
	option_15.value = option_15.__value = "webp";
	var option_16 = sibling(option_15);
	option_16.value = option_16.__value = "avif";
	var option_17 = sibling(option_16);
	option_17.value = option_17.__value = "jpeg";
	var option_18 = sibling(option_17);
	option_18.value = option_18.__value = "png";
	reset(select_2);
	reset(label_3);
	RangeNumber(sibling(label_3, 2), {
		label: "Quality",
		min: 0,
		max: 100,
		step: 1,
		get value() {
			return get(state).quality;
		},
		set value($$value) {
			mutate(state, get(state).quality = $$value);
		},
		$$legacy: true
	});
	reset(section_2);
	var section_3 = sibling(section_2, 2);
	var label_4 = sibling(child(section_3), 2);
	var select_3 = sibling(child(label_4), 2);
	var option_19 = child(select_3);
	option_19.value = option_19.__value = "images/dog.jpg";
	var option_20 = sibling(option_19);
	option_20.value = option_20.__value = "images/cat-300.jpg";
	reset(select_3);
	reset(label_4);
	var label_5 = sibling(label_4, 2);
	var select_4 = sibling(child(label_5), 2);
	var option_21 = child(select_4);
	option_21.value = option_21.__value = "_";
	var option_22 = sibling(option_21);
	option_22.value = option_22.__value = "unsafe";
	reset(select_4);
	reset(label_5);
	reset(section_3);
	reset(div_1);
	var div_7 = sibling(div_1, 2);
	var button_2 = child(div_7);
	var text_2 = child(button_2, true);
	reset(button_2);
	var a = sibling(button_2, 2);
	reset(div_7);
	reset(aside);
	var section_4 = sibling(aside, 2);
	var header = child(section_4);
	var button_3 = child(header);
	var code = sibling(button_3, 2);
	var text_3 = child(code, true);
	reset(code);
	var div_8 = sibling(code, 2);
	var button_4 = child(div_8);
	var text_4 = child(button_4, true);
	reset(button_4);
	var a_1 = sibling(button_4, 2);
	reset(div_8);
	reset(header);
	var div_9 = sibling(header, 2);
	var div_10 = child(div_9);
	var figure = child(div_10);
	var img = child(figure);
	var figcaption = sibling(img, 2);
	var span = child(figcaption);
	var text_5 = child(span, true);
	reset(span);
	var span_1 = sibling(span, 2);
	var text_6 = child(span_1, true);
	reset(span_1);
	reset(figcaption);
	reset(figure);
	reset(div_10);
	reset(div_9);
	reset(section_4);
	reset(main);
	template_effect(() => {
		classes = set_class(button, 1, "mobile-scrim svelte-1cfu4yu", null, classes, { "is-open": get(drawerOpen) });
		classes_1 = set_class(aside, 1, "tools-sidebar svelte-1cfu4yu", null, classes_1, { "is-open": get(drawerOpen) });
		set_text(text, (get(state), untrack(() => get(state).resizeEnabled ? `rs:${get(state).resizeMode}:${get(state).width}:${get(state).height}` : "Off")));
		set_text(text_1, (get(state), untrack(() => get(state).cropEnabled ? `c:${get(state).cropWidth}:${get(state).cropHeight}` : "Off")));
		set_text(text_2, get(copyLabel));
		set_attribute(a, "href", get(path));
		set_text(text_3, get(previewParameters));
		set_text(text_4, get(copyLabel));
		set_attribute(a_1, "href", get(path));
		set_attribute(img, "src", get(path));
		set_text(text_5, get(sizeLabel));
		set_text(text_6, get(outputLabel));
	});
	delegated("click", button, () => set(drawerOpen, false));
	delegated("click", button_1, () => set(drawerOpen, false));
	bind_select_value(select_2, () => get(state).format, ($$value) => mutate(state, get(state).format = $$value));
	bind_select_value(select_3, () => get(state).source, ($$value) => mutate(state, get(state).source = $$value));
	bind_select_value(select_4, () => get(state).signature, ($$value) => mutate(state, get(state).signature = $$value));
	delegated("click", button_2, copyUrl);
	delegated("click", button_3, () => set(drawerOpen, true));
	delegated("click", button_4, copyUrl);
	event("load", img, updateProcessedMetadata);
	replay_events(img);
	append($$anchor, main);
	pop();
}
delegate(["click"]);
//#endregion
//#region demo/src/main.ts
var target = document.getElementById("demo-app");
if (!(target instanceof HTMLElement)) throw new Error("Demo root element is missing");
mount(App, { target });
//#endregion
