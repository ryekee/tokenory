// [INPUT]: Demo model rates, usage clicks, metric and sound controls.
// [OUTPUT]: Token and cost totals, decimal drum motion and completion status.
// [POS]: Homepage HUD demo, following the native single-roll timing in HUDReading.swift.
const stage = document.querySelector(".stage");
const readout = stage.querySelector(".readout");
const announcement = stage.querySelector("output");
const hardware = stage.querySelector(".hardware");
const metricButtons = [...hardware.querySelectorAll("[data-metric]")];
const speaker = hardware.querySelector(".sound-button");
const runButton = stage.querySelector(".run-counter");
const flightLayer = stage.querySelector(".hud-flight-layer");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const locale = document.documentElement.lang;
const tokenFormat = new Intl.NumberFormat(locale);
const currencyOptions = { style: "currency", currency: "USD", currencyDisplay: "narrowSymbol" };
const costFormat = new Intl.NumberFormat(locale, currencyOptions);
const flightCostFormat = new Intl.NumberFormat(locale, { ...currencyOptions, maximumFractionDigits: 4 });

// Use integer picodollars so per-token prices can add up before display rounding.
const costUnitsPerDollar = 1e12;
const models = JSON.parse(runButton.dataset.models).map(({ name, input, output }) => ({
    name,
    input: Math.round(input * costUnitsPerDollar / 1e6),
    output: Math.round(output * costUnitsPerDollar / 1e6),
}));
const totals = { tokens: 128648, cost: 1864 * costUnitsPerDollar / 100 };
const metrics = Object.keys(totals);
const resting = Object.fromEntries(metrics.map((key) => [key, displayValue(key)]));
const motions = {};

const duration = 4.2;
const burstLimit = 6;
const gestureGap = 0.4;
const carryFraction = 0.8;
const readableTeethPerSecond = 14.88;
const flightDuration = 0.68;

let metric = "tokens";
let tracks = [];
let layout;
let flightGeometry;
let frame = 0;
let pendingStart;
let rollStart;
let rollEnd = 0;
let pendingBurst = false;
let lastUsageClick = -Infinity;
let settlement;
let audio;
let gain;
let click;
let lastClick = -Infinity;

function displayValue(key) {
    return key === "tokens" ? totals.tokens : Math.round(totals.cost / (costUnitsPerDollar / 100));
}

function format(key, value) {
    return key === "tokens" ? tokenFormat.format(value) : costFormat.format(value / 100);
}

function updateLayout() {
    const text = format(metric, motions[metric]?.target ?? resting[metric]);
    const structure = text.replace(/\d/g, "0");
    if (structure === layout) return;

    let place = text.match(/\d/g).length;
    readout.style.setProperty("--digits", place);
    tracks = [];
    readout.replaceChildren(...[...text].map((character) => {
        const slot = document.createElement("span");
        if (!/\d/.test(character)) {
            slot.className = "punct";
            slot.textContent = character;
            return slot;
        }

        const track = document.createElement("span");
        slot.className = "drum";
        track.className = "drum-track";
        // The repeated zero keeps nine-to-zero motion continuous across the wrap.
        for (let number = 0; number <= 10; number++) {
            const digit = document.createElement("span");
            digit.textContent = number % 10;
            track.append(digit);
        }
        slot.append(track);
        place--;
        tracks[place] = { slot, track, power: 10 ** place, fast: false };
        return slot;
    }));
    layout = structure;
    flightGeometry = undefined;
}

function drumPosition(value, { power }, motion) {
    if (power === 1) return value;
    const digit = Math.floor(value / power);
    const boundary = (digit + 1) * power;
    if (!motion || boundary > motion.target) return digit;

    // Spread the carry across the lower wheel's turn so it spans visible
    // frames even when the units drum crosses several teeth per frame.
    const anchor = motion.carryStarts.get(power);
    const start = anchor?.boundary === boundary ? anchor.start : boundary - power * carryFraction;
    const progress = Math.max(0, (value - start) / (boundary - start));
    return digit + progress * progress * (3 - 2 * progress);
}

function draw(now) {
    const motion = motions[metric];
    const { position: value, speed } = motion ? sample(motion, now) : { position: resting[metric], speed: 0 };
    let crossedTooth = false;
    for (const track of tracks) {
        const position = drumPosition(value, track, motion);
        const tooth = Math.floor(position);
        crossedTooth ||= track.tooth !== undefined && track.tooth !== tooth;
        track.tooth = tooth;
        const fast = speed / track.power > readableTeethPerSecond;
        if (track.fast !== fast) {
            track.slot.classList.toggle("is-fast", fast);
            track.fast = fast;
        }
        const offset = position % 10;
        if (track.offset !== offset) {
            track.track.style.transform = `translateY(${-100 * offset}%)`;
            track.offset = offset;
        }
    }
    return crossedTooth;
}

function announce(done = false) {
    const label = metricButtons.find((button) => button.dataset.metric === metric).getAttribute("aria-label");
    const value = format(metric, displayValue(metric));
    announcement.textContent = done ? `${runButton.dataset.done} · ${label} · ${value}` : `${label} · ${value}`;
}

function sample(motion, now) {
    const time = Math.max(0, now - motion.startTime);
    if (now >= motion.endTime) return { position: motion.target, speed: 0 };
    if (time < motion.accelerate) {
        const rate = (motion.peak - motion.initialSpeed) / motion.accelerate;
        return {
            position: motion.start + motion.initialSpeed * time + rate * time ** 2 / 2,
            speed: motion.initialSpeed + rate * time,
        };
    }
    const remaining = motion.endTime - now;
    if (remaining > motion.brake) {
        return { position: motion.target - motion.peak * (remaining - 2 * motion.brake / 3), speed: motion.peak };
    }
    const brakeFraction = remaining / motion.brake;
    return {
        position: motion.target - motion.peak * motion.brake * brakeFraction ** 3 / 3,
        speed: motion.peak * brakeFraction ** 2,
    };
}

function retarget(now) {
    const time = rollEnd - now;
    for (const key of metrics) {
        const target = displayValue(key);
        const prior = motions[key];
        const { position: start, speed: initialSpeed } = prior
            ? sample(prior, now)
            : { position: resting[key], speed: 0 };
        const distance = target - start;
        if (!distance) continue;

        // Preserve the incoming velocity. A shorter ramp leaves room to brake
        // when the drum already has enough speed to cover the remaining distance.
        const accelerate = Math.min(time * 0.16, distance / initialSpeed);
        const brake = time * 0.66;
        const peak = (distance - initialSpeed * accelerate / 2) / (time - accelerate / 2 - 2 * brake / 3);
        const carryStarts = new Map();
        for (let power = 10; power <= target; power *= 10) {
            const boundary = (Math.floor(start / power) + 1) * power;
            if (boundary > target) continue;
            const oldAnchor = prior?.carryStarts.get(power);
            const engagement = boundary - power * carryFraction;
            // A newly reachable carry starts from the displayed digit. A
            // carry already in flight keeps its existing engagement point.
            const carryStart = oldAnchor?.boundary === boundary ? oldAnchor.start
                : boundary <= (prior?.target ?? 0) ? engagement : Math.max(start, engagement);
            carryStarts.set(power, { boundary, start: carryStart });
        }
        motions[key] = { start, target, startTime: now, endTime: rollEnd, initialSpeed, accelerate, brake, peak, carryStarts };
    }
    updateLayout();
}

function roll(timestamp) {
    frame = 0;
    flightGeometry = undefined;
    const now = timestamp / 1000;
    if (reducedMotion.matches) {
        flightLayer?.getAnimations({ subtree: true }).forEach((animation) => animation.cancel());
        finish(now);
        return;
    }

    if (pendingStart !== undefined) {
        if (now < pendingStart) {
            frame = requestAnimationFrame(roll);
            return;
        }
        rollStart = pendingStart;
        rollEnd = rollStart + (pendingBurst ? burstLimit : duration);
        pendingStart = undefined;
        retarget(rollStart);
        stage.classList.add("is-rolling");
    }

    if (draw(now)) tick();
    if (now < rollEnd) frame = requestAnimationFrame(roll);
    else finish(now);
}

function refreshResting(now, done = false) {
    for (const key of metrics) resting[key] = displayValue(key);
    updateLayout();
    draw(now);
    announce(done);
}

function finish(now) {
    cancelAnimationFrame(frame);
    frame = 0;
    pendingStart = undefined;
    rollEnd = 0;
    flightGeometry = undefined;
    for (const key of metrics) motions[key] = undefined;
    stage.classList.remove("is-rolling");
    refreshResting(now, true);
    stage.classList.add("is-settled");
    settlement = setTimeout(() => stage.classList.remove("is-settled"), 800);
}

function recordUsage(input, output, cost, now, flightTime) {
    const sameGesture = now - lastUsageClick <= gestureGap;
    lastUsageClick = now;
    const deadline = pendingStart === undefined ? rollEnd : pendingStart + (pendingBurst ? burstLimit : duration);
    const expired = deadline && now >= deadline;
    if (expired && !sameGesture) finish(now);

    totals.tokens += input + output;
    totals.cost += cost;

    if (reducedMotion.matches || (expired && sameGesture)) {
        if (pendingStart !== undefined || rollEnd || !sameGesture) finish(now);
        else refreshResting(now);
    } else if (pendingStart !== undefined) {
        pendingBurst = true;
    } else if (rollEnd) {
        rollEnd = rollStart + burstLimit;
        retarget(now);
    } else if (sameGesture) {
        // The same gesture can keep crediting usage at rest after its fixed deadline.
        refreshResting(now);
    } else {
        clearTimeout(settlement);
        stage.classList.remove("is-settled");
        pendingStart = now + flightTime;
        pendingBurst = false;
        frame = requestAnimationFrame(roll);
    }
}

function fly(model, input, output, cost) {
    if (!flightLayer || reducedMotion.matches || !Element.prototype.animate) return 0;
    if (!flightGeometry) {
        const layer = flightLayer.getBoundingClientRect();
        const button = runButton.getBoundingClientRect();
        const target = readout.getBoundingClientRect();
        flightGeometry = {
            fromX: button.left + button.width / 2 - layer.left,
            fromY: button.top + button.height / 2 - layer.top,
            toX: target.left + target.width / 2 - layer.left,
            toY: target.top + target.height * 0.65 - layer.top,
        };
    }
    const { fromX, fromY, toX, toY } = flightGeometry;
    const sway = (Math.random() - 0.5) * 64;

    const flight = document.createElement("span");
    const name = document.createElement("strong");
    const tokens = document.createElement("span");
    const amount = document.createElement("span");
    name.textContent = model;
    tokens.textContent = `${runButton.dataset.input || "In"} +${tokenFormat.format(input)} · ${runButton.dataset.output || "Out"} +${tokenFormat.format(output)}`;
    amount.textContent = `+${flightCostFormat.format(cost / costUnitsPerDollar)}`;
    flight.className = "hud-flight";
    flight.append(name, tokens, amount);
    flightLayer.append(flight);

    const keyframes = [0, 0.15, 0.35, 0.6, 0.8, 1].map((time) => {
        // A parabolic path leaves the button quickly and curves into the readout.
        const x = fromX + (toX - fromX) * time + sway * 4 * time * (1 - time);
        const y = fromY + (toY - fromY) * (1.58 * time - 0.58 * time ** 2);
        return {
            offset: time,
            transform: `translate(${x}px, ${y}px) translate(-50%, -50%) scale(${1 - 0.36 * time ** 3})`,
            opacity: Math.min(1, time / 0.08, (1 - time) / 0.19),
        };
    });
    const animation = flight.animate(keyframes, { duration: flightDuration * 1000, fill: "both" });
    animation.finished.then(() => flight.remove(), () => flight.remove());
    return flightDuration;
}

function unlockAudio() {
    if (!window.AudioContext) return;
    if (!audio) {
        audio = new AudioContext();
        gain = audio.createGain();
        gain.gain.value = 0.32;
        gain.connect(audio.destination);
        const length = Math.round(audio.sampleRate * 0.035);
        click = audio.createBuffer(1, length, audio.sampleRate);
        const samples = click.getChannelData(0);
        for (let i = 0; i < length; i++) {
            const t = i / audio.sampleRate;
            samples[i] = 0.48 * (Math.random() * 2 - 1) * Math.exp(-t * 270)
                + 0.3 * Math.sin(t * 2 * Math.PI * 1250) * Math.exp(-t * 190)
                + 0.2 * Math.sin(t * 2 * Math.PI * 360) * Math.exp(-t * 130);
        }
    }
    audio.resume().catch(() => {});
}

function tick() {
    if (speaker.getAttribute("aria-pressed") !== "true" || audio?.state !== "running") return;
    if (audio.currentTime - lastClick < 0.027) return;
    lastClick = audio.currentTime;
    const source = audio.createBufferSource();
    source.buffer = click;
    source.connect(gain);
    source.onended = () => source.disconnect();
    source.start();
}

runButton.addEventListener("click", () => {
    if (speaker.getAttribute("aria-pressed") === "true") unlockAudio();
    if (!frame) flightGeometry = undefined;

    const model = models[Math.floor(Math.random() * models.length)];
    const input = 1000 + Math.floor(Math.random() * 8000);
    const output = 400 + Math.floor(Math.random() * 2600);
    const cost = input * model.input + output * model.output;
    const now = performance.now() / 1000;
    recordUsage(input, output, cost, now, fly(model.name, input, output, cost));
});

for (const button of metricButtons) {
    button.addEventListener("click", () => {
        if (button.dataset.metric === metric) return;
        metric = button.dataset.metric;
        for (const item of metricButtons) item.setAttribute("aria-pressed", String(item === button));
        updateLayout();
        draw(performance.now() / 1000);
        if (!frame) announce();
    });
}

speaker.addEventListener("click", () => {
    const enabled = speaker.getAttribute("aria-pressed") !== "true";
    speaker.setAttribute("aria-pressed", String(enabled));
    if (enabled) unlockAudio();
    if (gain) gain.gain.value = enabled ? 0.32 : 0;
});

reducedMotion.addEventListener("change", () => {
    if (!reducedMotion.matches || !frame) return;
    cancelAnimationFrame(frame);
    roll(performance.now());
});

updateLayout();
draw(performance.now() / 1000);
announce();
hardware.hidden = false;
runButton.hidden = false;
