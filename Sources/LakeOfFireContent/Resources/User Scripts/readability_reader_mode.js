(function () {
    const wiredCarousels = new WeakMap();

    function logCarousel() {
        let parts = Array.from(arguments).map((part) => {
            if (typeof part === 'string') {
                return part;
            }
            try {
                return JSON.stringify(part);
            } catch (_error) {
                return String(part);
            }
        });
        let message = '# CAROUSEL ' + parts.join(' ');
        console.log(message);
        try {
            window.webkit?.messageHandlers?.print?.postMessage?.(message);
        } catch (_error) {}
    }

    function wireReadabilityCarousels() {
        let carousels = document.querySelectorAll('[data-readability-carousel="true"]');
        if (carousels.length > 0) {
            logCarousel('found', carousels.length);
        }
        for (let carousel of carousels) {
            if (wiredCarousels.has(carousel)) {
                logCarousel('skip already-wired');
                continue;
            }
            let track = carousel.querySelector('[data-readability-carousel-track]');
            if (!track) {
                logCarousel('skip missing-track', carousel.outerHTML.slice(0, 240));
                continue;
            }
            let slides = Array.from(track.querySelectorAll('[data-readability-carousel-slide]'));
            if (slides.length < 2) {
                logCarousel('skip insufficient-slides', slides.length);
                continue;
            }

            wiredCarousels.set(carousel, true);
            logCarousel('wire', slides.length);

            let controls = document.createElement('div');
            controls.setAttribute('data-readability-carousel-controls', '');

            let previousButton = document.createElement('button');
            previousButton.type = 'button';
            previousButton.textContent = '‹';
            previousButton.setAttribute('aria-label', 'Previous image');
            previousButton.setAttribute('data-readability-carousel-button', 'previous');

            let status = document.createElement('span');
            status.setAttribute('data-readability-carousel-status', '');
            status.setAttribute('aria-live', 'polite');

            let nextButton = document.createElement('button');
            nextButton.type = 'button';
            nextButton.textContent = '›';
            nextButton.setAttribute('aria-label', 'Next image');
            nextButton.setAttribute('data-readability-carousel-button', 'next');

            controls.append(previousButton, status, nextButton);
            carousel.appendChild(controls);

            let currentIndex = () => {
                let trackRect = track.getBoundingClientRect();
                let trackCenter = trackRect.left + (trackRect.width / 2);
                let bestIndex = 0;
                let bestDistance = Number.POSITIVE_INFINITY;
                for (let index = 0; index < slides.length; index += 1) {
                    let rect = slides[index].getBoundingClientRect();
                    let center = rect.left + (rect.width / 2);
                    let distance = Math.abs(center - trackCenter);
                    if (distance < bestDistance) {
                        bestDistance = distance;
                        bestIndex = index;
                    }
                }
                return bestIndex;
            };

            let updateControls = () => {
                let index = currentIndex();
                status.textContent = String(index + 1) + ' / ' + String(slides.length);
                previousButton.disabled = index <= 0;
                nextButton.disabled = index >= slides.length - 1;
                logCarousel('update', index + 1, slides.length, Math.round(track.scrollLeft));
            };

            let scrollToIndex = (index) => {
                let boundedIndex = Math.max(0, Math.min(index, slides.length - 1));
                logCarousel('scroll', boundedIndex + 1, slides.length);
                slides[boundedIndex].scrollIntoView({
                    behavior: 'smooth',
                    block: 'nearest',
                    inline: 'center',
                });
            };

            previousButton.addEventListener('click', () => scrollToIndex(currentIndex() - 1));
            nextButton.addEventListener('click', () => scrollToIndex(currentIndex() + 1));
            track.addEventListener('scroll', () => window.requestAnimationFrame(updateControls), { passive: true });
            updateControls();
        }
    }

    function init() {
        if (document.body?.classList.contains('readability-mode')) {
            wireReadabilityCarousels();
            new MutationObserver(() => wireReadabilityCarousels())
                .observe(document, { childList: true, subtree: true, attributes: false });
        } else {
            const observer = new MutationObserver(() => {
                if (document.body?.classList.contains('readability-mode')) {
                    observer.disconnect();
                    init();
                }
            });
            observer.observe(document.body, { attributes: true, attributeFilter: ['class'] });
        }
    }

    if (document.readyState === 'complete') {
        init();
    } else {
        document.addEventListener('DOMContentLoaded', init);
    }
})();
