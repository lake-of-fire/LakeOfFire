// Forked from https://github.com/mozilla/firefox-ios/blob/f0aa52986f0ae7e44d45ede0ff0ef31fa9eb4783/Client/Frontend/Reader/ReaderMode.js

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

(function () {
    const isEbook = window.top.location.origin.startsWith('ebook://');
    if (isEbook) {
        return;
    }
    const MANAGED_APPLIED_DATASET_KEY = "manabiManagedReaderImageSizing";
    const LEGACY_SIGNATURE_DATASET_KEY = "manabiLastCss";
    const WRAPPER_INLINE_FLOW_CLASS = "manabi-vertical-inline-image-wrapper";
    const MANAGED_DATASET_FLAG = "1";

    function hasDatasetKey(element, key) {
        return !!element && !!element.dataset && Object.prototype.hasOwnProperty.call(element.dataset, key);
    }

    function isLegacyManagedInlineValue(value, priority) {
        const normalizedValue = (value || "").replace(/\s+/g, " ").trim().toLowerCase();
        if (priority !== "important") {
            return false;
        }
        return normalizedValue.includes("min(") && normalizedValue.includes("850px");
    }

    function clearManagedImageSizing(img) {
        if (!(img instanceof HTMLImageElement)) {
            return;
        }
        const maxWidthValue = img.style.getPropertyValue("max-width") || "";
        const maxWidthPriority = img.style.getPropertyPriority("max-width") || "";
        const widthValue = img.style.getPropertyValue("width") || "";
        const widthPriority = img.style.getPropertyPriority("width") || "";
        const shouldClear =
            img.dataset[MANAGED_APPLIED_DATASET_KEY] === MANAGED_DATASET_FLAG
            || hasDatasetKey(img, LEGACY_SIGNATURE_DATASET_KEY)
            || isLegacyManagedInlineValue(maxWidthValue, maxWidthPriority)
            || isLegacyManagedInlineValue(widthValue, widthPriority);
        if (!shouldClear) {
            return;
        }
        img.style.removeProperty("max-width");
        img.style.removeProperty("width");
        delete img.dataset[MANAGED_APPLIED_DATASET_KEY];
        delete img.dataset[LEGACY_SIGNATURE_DATASET_KEY];
    }

    function applyManagedImageSizing(img, maxWidthStyle, widthStyle) {
        if (!(img instanceof HTMLImageElement)) {
            return;
        }
        img.style.setProperty("max-width", maxWidthStyle, "important");
        if (widthStyle) {
            img.style.setProperty("width", widthStyle, "important");
        } else {
            img.style.removeProperty("width");
        }
        img.dataset[MANAGED_APPLIED_DATASET_KEY] = MANAGED_DATASET_FLAG;
        delete img.dataset[LEGACY_SIGNATURE_DATASET_KEY];
    }

    function imageOnlyWrapperForInlineFlow(img) {
        if (!(img instanceof HTMLImageElement)) {
            return null;
        }
        let chainNode = img;
        while (true) {
            const parent = chainNode.parentElement;
            if (!parent) {
                break;
            }
            const parentTagName = parent.tagName?.toUpperCase() || "";
            const canInlineChainThrough = parentTagName === "PICTURE" || parentTagName === "A";
            if (!canInlineChainThrough) {
                break;
            }
            if (parent.children.length !== 1 || parent.firstElementChild !== chainNode) {
                break;
            }
            chainNode = parent;
        }

        const wrapper = chainNode.parentElement;
        if (!wrapper) {
            return null;
        }

        const wrapperTagName = wrapper.tagName?.toUpperCase() || "";
        if (wrapperTagName !== "P" && wrapperTagName !== "DIV") {
            return null;
        }

        if (wrapper.children.length !== 1) {
            return null;
        }
        if (wrapper.firstElementChild === chainNode) {
            return wrapper;
        }
        return null;
    }

    function enforceReaderContentImagePresentation(img) {
        if (!(img instanceof HTMLImageElement)) {
            return;
        }
        img.style.setProperty("border-radius", "6px", "important");

        const pictureParent = img.parentElement?.tagName?.toUpperCase() === "PICTURE"
            ? img.parentElement
            : null;
        if (pictureParent instanceof HTMLElement) {
            pictureParent.style.setProperty("border-radius", "6px", "important");
            pictureParent.style.setProperty("overflow", "hidden", "important");
        }
    }

    function applyVerticalInlineImageFlowForImage(img) {
        const wrapper = imageOnlyWrapperForInlineFlow(img);
        if (!(wrapper instanceof HTMLElement)) {
            return;
        }
        wrapper.classList.add(WRAPPER_INLINE_FLOW_CLASS);
    }

    function clearVerticalInlineImageFlow() {
        const wrappers = document.querySelectorAll(
            `#reader-content .${WRAPPER_INLINE_FLOW_CLASS}`
        );
        wrappers.forEach((wrapper) => {
            wrapper.classList.remove(WRAPPER_INLINE_FLOW_CLASS);
        });
    }
 
    function updateImageMargins() {
        var BLOCK_IMAGES_SELECTOR = "#reader-header > img, " +
        "#reader-content p > img:only-child, " +
        "#reader-content p > a:only-child > img:only-child, " +
        "#reader-content div > img:only-child, " +
        "#reader-content div > a:only-child > img:only-child, " +
        "#reader-content > img, " +
        "#reader-content .wp-caption img, " +
        "#reader-content figure img";
        
        if (!document.body?.classList.contains('readability-mode')) {
            return;
        }
        const writingDirectionOverride = document.body?.dataset?.manabiWritingDirection || "automatic";
        const isVertical = writingDirectionOverride === "vertical"
            || (
                writingDirectionOverride !== "horizontal"
                && document.body?.classList?.contains('reader-vertical-writing') === true
            );
        const contentElement = document.getElementById("reader-content");
        if (contentElement === null) {
            return;
        }

        if (isVertical) {
            const managedOrLegacyImages = document.querySelectorAll(
                "#reader-header > img, #reader-content img"
            );
            managedOrLegacyImages.forEach(clearManagedImageSizing);
            clearVerticalInlineImageFlow();
            const readerContentImages = document.querySelectorAll("#reader-content img");
            readerContentImages.forEach((img) => {
                enforceReaderContentImagePresentation(img);
                applyVerticalInlineImageFlowForImage(img);
            });
            return;
        }
        clearVerticalInlineImageFlow();
        
        var contentWidth = contentElement.offsetWidth;
        
        Array.from(document.getElementsByTagName('img')).forEach(img => {
            // Reset cached dimensions so we recalc from natural size
            delete img._originalWidth;
            delete img._originalHeight;
        });
        
        var maxWidthStyle = "min(850px, 100%)";
        
        var setImageMargins = function (img) {
            if (!img._originalWidth) {
                img._originalWidth = img.naturalWidth || img.offsetWidth;
            }
            if (!img._originalHeight) {
                img._originalHeight = img.naturalHeight || img.offsetHeight;
            }
            
            var imgWidth = img._originalWidth;
            
            var widthStyle = "";
            if (imgWidth < contentWidth * 0.2) {
                widthStyle = "min(850px, 45%, " + imgWidth * 1.3 + "px)";
            } else if (imgWidth < contentWidth * 0.5) {
                widthStyle = "min(" + contentWidth.toString() + "px, 850px, " + (imgWidth * 2).toString() + "px)";
            } else if (imgWidth < contentWidth) {
                widthStyle = maxWidthStyle;
            }
            
            enforceReaderContentImagePresentation(img);
            applyManagedImageSizing(img, maxWidthStyle, widthStyle);
            return;
        }
        
        var likelyBlockImages = document.querySelectorAll(BLOCK_IMAGES_SELECTOR);
        var candidateImages = Array.from(likelyBlockImages);
        /*var allImages = document.querySelectorAll("#reader-content img");
         
         // For images not already in candidateImages, check their rendered width and add if it's >= half of 850px.
         for (var i = 0; i < allImages.length; i++) {
         var img = allImages[i];
         if (candidateImages.indexOf(img) === -1) {
         var rect = img.getBoundingClientRect();
         if (rect.width >= 425) {
         candidateImages.push(img);
         }
         }
         }
         */
        for (var i = candidateImages.length - 1; i >= 0; i--) {
            var img = candidateImages[i];
            if (img.width > 0) {
                setImageMargins(img);
            } else {
                img.onload = function() {
                    setImageMargins(this);
                };
            }
        }
    };
    
    var timer;
    function debounce(func){
        return function(event){
            if (timer) clearTimeout(timer);
            timer = setTimeout(func, 250, event);
        };
    }
    
    const debouncedUpdateImageMargins = debounce(updateImageMargins);
    window.manabiUpdateReadabilityImageMargins = updateImageMargins;
    
    function initialize() {
        var observer = new MutationObserver(function (mutations) {
            mutations.forEach(function (mutation) {
                mutation.addedNodes.forEach(addedNode => {
                    if (addedNode.tagName?.toUpperCase() === 'IMG') {
                        debouncedUpdateImageMargins()
                    }
                });
            })
        })
        observer.observe(document.documentElement, {
            attributes: false,
            childList: true,
            subtree: true,
        })
        window.addEventListener('resize', debouncedUpdateImageMargins);
        
        updateImageMargins()
    }
    
    if (document.readyState === 'complete') {
        initialize()
    } else {
        document.addEventListener("DOMContentLoaded", function (event) {
            initialize()
        }, false)
    };
})();
