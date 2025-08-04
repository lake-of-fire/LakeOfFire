// Forked from https://github.com/mozilla/firefox-ios/blob/f0aa52986f0ae7e44d45ede0ff0ef31fa9eb4783/Client/Frontend/Reader/ReaderMode.js

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

(function () {
    const isEbook = window.top.location.origin.startsWith('ebook://');
    if (isEbook) {
        return;
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
        const contentElement = document.getElementById("reader-content");
        if (contentElement === null) {
            return;
        }
        
        var contentWidth = contentElement.offsetWidth;
        
        Array.from(document.getElementsByTagName('img')).forEach(img => {
            // Reset cached dimensions so we recalc from natural size
            delete img._originalWidth;
            delete img._originalHeight;
        });
        
        var maxWidthStyle = "min(850px, 100%) !important";
        
        var setImageMargins = function (img) {
            if (!img._originalWidth) {
                img._originalWidth = img.naturalWidth || img.offsetWidth;
            }
            if (!img._originalHeight) {
                img._originalHeight = img.naturalHeight || img.offsetHeight;
            }
            
            var imgWidth = img._originalWidth;
            let imgHeight = img._originalHeight;
            
            var widthStyle = "";
            if (imgWidth < contentWidth * 0.2) {
                widthStyle = "min(850px, 45%, " + imgWidth * 1.3 + "px) !important";
            } else if (imgWidth < contentWidth * 0.5) {
                widthStyle = "min(" + contentWidth.toString() + "px, 850px, " + (imgWidth * 2).toString() + "px) !important";
            } else if (imgWidth < contentWidth) {
                widthStyle = maxWidthStyle;
            }
            
            // Compute CSS text first
            var cssText =
            "max-width: " + maxWidthStyle + ";" +
            "width: " + widthStyle + ";";
            // If style hasn’t changed, skip reapplying
            if (img.dataset.manabiLastCss === cssText) {
                return;
            }
            img.dataset.manabiLastCss = cssText;
            img.style.cssText = cssText;
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
