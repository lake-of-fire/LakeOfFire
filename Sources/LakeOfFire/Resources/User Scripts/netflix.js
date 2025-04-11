// Forked from https://github.com/Haksa6/doublesubadub

(function initializeSubadub() {
     const POLL_INTERVAL_MS = 500;
     const MANIFEST_URL = "/manifest";
     const WEBVTT_FMT = "webvtt-lssdh-ios8";
     
     const SUBS_LIST_ELEM_ID = "subadub-subs-list";
     const TOGGLE_DISPLAY_BUTTON_ID = "subadub-toggle-display";
     const TRACK_ELEM_ID = "subadub-track";
     const DOWNLOAD_BUTTON_ID = "subadub-download";
     const CUSTOM_SUBS_ELEM_ID = "subadub-custom-subs";
     
     const NETFLIX_PROFILES = [
         "heaac-2-dash",
         "heaac-2hq-dash",
         "playready-h264mpl30-dash",
         "playready-h264mpl31-dash",
         "playready-h264hpl30-dash",
         "playready-h264hpl31-dash",
         "vp9-profile0-L30-dash-cenc",
         "vp9-profile0-L31-dash-cenc",
         "dfxp-ls-sdh",
         "simplesdh",
         "nflx-cmisc",
         "BIF240",
         "BIF320",
     ];
     
     const trackListCache = new Map(); // from movie ID to list of available tracks
     const webvttCache = new Map(); // from 'movieID/trackID' to blob
     let urlMovieId; // this is mis-named now, it's pulled from the HTML
     let selectedTrackId;
     let selectedTrackId2; // New secondary track
     let showSubsState = true;
     
     let targetSubsList = null;
     let displayedSubsList = null;
     
     let targetTrackBlob = null;
     let displayedTrackBlob = null;
     let displayedTrackBlob2 = null;
     
     // Convert WebVTT text to plain text plus "simple" tags (allowed in SRT)
     const TAG_REGEX = RegExp("</?([^>]*)>", "ig");
     function vttTextToSimple(s, netflixRTLFix) {
         let simpleText = s;
         
         // strip tags except simple ones
         simpleText = simpleText.replace(TAG_REGEX, function (match, p1) {
             return ["i", "u", "b"].includes((p1 || "").toLowerCase()) ? match : "";
         });
         
         if (netflixRTLFix) {
             // For each line, if it starts with lrm or rlm escape, wrap in LRE/RLE/PDF pair.
             // This is weird, but needed for compatibility with Netflix. See issue #1.
             const lines = simpleText.split("\n");
             const newLines = [];
             for (const line of lines) {
                 if (line.startsWith("&lrm;")) {
                     newLines.push("\u202a" + line.slice(5) + "\u202c");
                 } else if (line.startsWith("&rlm;")) {
                     newLines.push("\u202b" + line.slice(5) + "\u202c");
                 } else {
                     newLines.push(line);
                 }
             }
             simpleText = newLines.join("\n");
         }
         
         return simpleText;
     }
     
     function extractMovieTextTracks(movieObj) {
         const movieId = movieObj.movieId;
         
         const usableTracks = [];
         console.log("timedtexttracks", movieObj.timedtexttracks);
         for (const track of movieObj.timedtexttracks) {
             console.log(track.language);
             if (track.isForcedNarrative || track.isNoneTrack) {
                 console.log("A");
                 continue; // don't want these
             }
             
             if (!track.ttDownloadables) {
                 console.log("B");
                 continue;
             }
             
             const webvttDL = track.ttDownloadables[WEBVTT_FMT];
             console.log("webvttDL", webvttDL);
             if (!webvttDL || !webvttDL.urls) {
                 console.log("C");
                 continue;
             }
             
             const bestUrl = webvttDL.urls[0].url;
             
             if (!bestUrl) {
                 console.log("D");
                 continue;
             }
             
             const isClosedCaptions = track.rawTrackType === "closedcaptions";
             
             usableTracks.push({
                 id: track.new_track_id,
                 language: track.language,
                 languageDescription: track.languageDescription,
                 bestUrl: bestUrl,
                 isClosedCaptions: isClosedCaptions,
             });
         }
         
         console.log("CACHING MOVIE TRACKS", movieId, usableTracks);
         trackListCache.set(movieId, usableTracks);
         renderAndReconcile();
     }
     
     function getSelectedTrackInfo() {
         if (!urlMovieId || !selectedTrackId) {
             throw new Error(
                             "Internal error, getSelectedTrackInfo called but urlMovieId or selectedTrackId is null"
                             );
         }
         const trackList = trackListCache.get(urlMovieId);
         const matchingTracks = trackList.filter((el) => el.id === selectedTrackId);
         if (matchingTracks.length !== 1) {
             throw new Error("internal error, no matching track id");
         }
         return matchingTracks[0];
     }
     function getSelectedTrackInfo2() {
         if (!urlMovieId || !selectedTrackId2) {
             throw new Error(
                             "Internal error, getSelectedTrackInfo2 called but urlMovieId or selectedTrackId2 is null"
                             );
         }
         const trackList = trackListCache.get(urlMovieId);
         const matchingTracks = trackList.filter((el) => el.id === selectedTrackId2);
         if (matchingTracks.length !== 1) {
             throw new Error("internal error, no matching track id");
         }
         return matchingTracks[0];
     }
     
     function handleSubsListSetOrChange(selectElem, isPrimary = true) {
         const trackId = selectElem.value;
         
         if (isPrimary) {
             selectedTrackId = trackId;
         } else {
             selectedTrackId2 = trackId;
         }
         
         if ((!isPrimary && !selectedTrackId2) || (isPrimary && !selectedTrackId)) {
             return;
         }
         
         const trackIdToUse = isPrimary ? selectedTrackId : selectedTrackId2;
         const cacheKey = urlMovieId + "/" + trackIdToUse;
         
         if (!webvttCache.has(cacheKey)) {
             const trackInfo = isPrimary
             ? getSelectedTrackInfo()
             : getSelectedTrackInfo2();
             const url = trackInfo.bestUrl;
             
             fetch(url)
             .then(function (response) {
                 if (response.ok) {
                     return response.blob();
                 }
                 throw new Error("Bad response to WebVTT request");
             })
             .then(function (blob) {
                 webvttCache.set(cacheKey, new Blob([blob], { type: "text/vtt" }));
                 renderAndReconcile();
             })
             .catch(function (error) {
                 console.error("Failed to fetch WebVTT file", error.message);
             });
         }
     }
     
     function enableDownloadButton() {
         const downloadButtonElem = document.getElementById(DOWNLOAD_BUTTON_ID);
         if (downloadButtonElem) {
             downloadButtonElem.style.color = "black";
             downloadButtonElem.disabled = false;
         }
     }
     
     function disableDownloadButton() {
         const downloadButtonElem = document.getElementById(DOWNLOAD_BUTTON_ID);
         if (downloadButtonElem) {
             downloadButtonElem.style.color = "grey";
             downloadButtonElem.disabled = true;
         }
     }
     
     function downloadSRT() {
         function formatTime(t) {
             const date = new Date(0, 0, 0, 0, 0, 0, t * 1000);
             const hours = date.getHours().toString().padStart(2, "0");
             const minutes = date.getMinutes().toString().padStart(2, "0");
             const seconds = date.getSeconds().toString().padStart(2, "0");
             const ms = date.getMilliseconds().toString().padStart(3, "0");
             
             return hours + ":" + minutes + ":" + seconds + "," + ms;
         }
         
         const trackElem = document.getElementById(TRACK_ELEM_ID);
         if (!trackElem || !trackElem.track || !trackElem.track.cues) {
             return;
         }
         
         // Figure out video title.
         let srtFilename;
         const videoMeta = netflix?.appContext?.state?.playerApp
         ?.getAPI?.()
         ?.getVideoMetadataByVideoId(urlMovieId.toString())
         ?.getCurrentVideo();
         if (videoMeta !== undefined) {
             srtFilename = videoMeta.getTitle();
             if (videoMeta.isEpisodic()) {
                 const season = `${videoMeta.getSeason()._season.seq}`.padStart(2, "0");
                 const ep = `${videoMeta.getEpisodeNumber()}`.padStart(2, "0");
                 const epTitle = videoMeta.getEpisodeTitle();
                 if (epTitle) {
                     srtFilename += `.S${season}E${ep}.${epTitle}`;
                 } else {
                     srtFilename += `.S${season}E${ep}`;
                 }
             }
         } else {
             srtFilename = urlMovieId.toString(); // fallback in case UI changes
         }
         srtFilename += "." + trackElem.track.language; // append language code
         srtFilename += ".srt";
         
         const srtChunks = [];
         let idx = 1;
         for (const cue of trackElem.track.cues) {
             const cleanedText = vttTextToSimple(cue.text, true);
             srtChunks.push(
                idx +
                "\n" +
                formatTime(cue.startTime) +
                " --> " +
                formatTime(cue.endTime) +
                "\n" +
                cleanedText +
                "\n\n"
            );
             idx++;
         }
         
         const srtBlob = new Blob(srtChunks, { type: "text/srt" });
         const srtUrl = URL.createObjectURL(srtBlob);
         
         const tmpElem = document.createElement("a");
         tmpElem.setAttribute("href", srtUrl);
         tmpElem.setAttribute("download", srtFilename);
         tmpElem.style.display = "none";
         document.body.appendChild(tmpElem);
         tmpElem.click();
         document.body.removeChild(tmpElem);
     }
     
     function updateToggleDisplay() {
         const buttomElem = document.getElementById(TOGGLE_DISPLAY_BUTTON_ID);
         if (buttomElem) {
             if (showSubsState) {
                 buttomElem.textContent = "Hide Subs [S]";
             } else {
                 buttomElem.textContent = "Show Subs [S]";
             }
         }
         const subsElem = document.getElementById(CUSTOM_SUBS_ELEM_ID);
         if (subsElem) {
             if (showSubsState) {
                 subsElem.style.visibility = "visible";
             } else {
                 subsElem.style.visibility = "hidden";
             }
         }
     }
     
     function renderAndReconcile() {
         function addSubsList(tracks) {
             const toggleDisplayButtonElem = document.createElement("button");
             toggleDisplayButtonElem.id = TOGGLE_DISPLAY_BUTTON_ID;
             toggleDisplayButtonElem.style.cssText =
             "margin: 5px; border: none; color: black; width: 8em";
             toggleDisplayButtonElem.addEventListener("click", function (e) {
                 e.preventDefault();
                 showSubsState = !showSubsState;
                 updateToggleDisplay();
             }, false);
             
             // Primary subtitle selector
             const selectElem = document.createElement("select");
             selectElem.style.cssText = "color: black; margin: 5px";
             selectElem.addEventListener("change", function (e) {
                 handleSubsListSetOrChange(e.target, true);
                 renderAndReconcile();
             }, false);
             
             // Secondary subtitle selector
             const select2Elem = document.createElement("select");
             select2Elem.style.cssText = "color: black; margin: 5px";
             select2Elem.addEventListener("change", function (e) {
                 handleSubsListSetOrChange(e.target, false);
                 renderAndReconcile();
             }, false);
             
             // Add "None" option for second subtitle
             const noneOption = document.createElement("option");
             noneOption.value = "";
             noneOption.textContent = "None";
             select2Elem.appendChild(noneOption);
             
             let firstCCTrackId;
             // Add options to both selectors
             for (const track of tracks) {
                 // Add to primary selector
                 const optElem = document.createElement("option");
                 optElem.value = track.id;
                 optElem.textContent =
                 track.languageDescription + (track.isClosedCaptions ? " [CC]" : "");
                 selectElem.appendChild(optElem.cloneNode(true));
                 
                 // Add to secondary selector
                 select2Elem.appendChild(optElem);
                 
                 if (track.isClosedCaptions && !firstCCTrackId) {
                     firstCCTrackId = track.id;
                 }
             }
             
             if (firstCCTrackId) {
                 selectElem.value = firstCCTrackId;
             }
             
             const downloadButtonElem = document.createElement("button");
             downloadButtonElem.id = DOWNLOAD_BUTTON_ID;
             downloadButtonElem.textContent = "Download SRT";
             downloadButtonElem.style.cssText = "margin: 5px; border: none";
             downloadButtonElem.addEventListener("click", function (e) {
                 e.preventDefault();
                 downloadSRT();
             }, false);
             
             const panelElem = document.createElement("div");
             panelElem.style.cssText =
             "position: absolute; z-index: 1000; top: 0; right: 0; font-size: 16px; color: white; pointer-events: auto";
             panelElem.appendChild(toggleDisplayButtonElem);
             panelElem.appendChild(selectElem);
             panelElem.appendChild(select2Elem);
             panelElem.appendChild(downloadButtonElem);
             
             const containerElem = document.createElement("div");
             containerElem.id = SUBS_LIST_ELEM_ID;
             containerElem.style.cssText =
             "width: 100%; height: 100%; position: absolute; top: 0; right: 0; bottom: 0; left: 0; pointer-events: none";
             containerElem.appendChild(panelElem);
             
             document.body.appendChild(containerElem);
             
             updateToggleDisplay();
             disableDownloadButton();
             
             handleSubsListSetOrChange(selectElem, true);
             handleSubsListSetOrChange(select2Elem, false);
         }
         
         function removeSubsList() {
             const el = document.getElementById(SUBS_LIST_ELEM_ID);
             if (el) {
                 el.remove();
             }
         }
         
         function addTrackElem(videoElem, blob, blob2, srclang, srclang2) {
             const trackElem = document.createElement("track");
             trackElem.id = TRACK_ELEM_ID;
             // TODO: Must URL.revokeObjectURL to avoid leak at some point
             trackElem.src = URL.createObjectURL(blob);
             trackElem.kind = "subtitles";
             trackElem.default = true;
             trackElem.srclang = srclang;
             videoElem.appendChild(trackElem);
             trackElem.track.mode = "hidden";
             
             // Second track if provided
             let trackElem2;
             if (blob2) {
                 trackElem2 = document.createElement("track");
                 trackElem2.id = TRACK_ELEM_ID + "2";
                 trackElem2.src = URL.createObjectURL(blob2);
                 trackElem2.kind = "subtitles";
                 trackElem2.srclang = srclang2;
                 videoElem.appendChild(trackElem2);
                 trackElem2.track.mode = "hidden";
             }
             
             trackElem.addEventListener("load", function () {
                 enableDownloadButton();
             }, false);
             
             const customSubsElem = document.createElement("div");
             customSubsElem.id = CUSTOM_SUBS_ELEM_ID;
             customSubsElem.style.cssText =
             "position: absolute; bottom: 20vh; left: 0; right: 0; color: white; font-size: 3vw; text-align: center; user-select: text; -moz-user-select: text; z-index: 100; pointer-events: none";
             
             function updateSubtitles() {
                 while (customSubsElem.firstChild) {
                     customSubsElem.removeChild(customSubsElem.firstChild);
                 }
                 
                 // Handle primary track
                 if (trackElem.track.activeCues) {
                     for (const cue of trackElem.track.activeCues) {
                         const cueElem = document.createElement("div");
                         cueElem.style.cssText =
                         "background: rgba(0,0,0,0.8); white-space: pre-wrap; padding: 0.2em 0.3em; margin: 10px auto; width: fit-content; width: -moz-fit-content; pointer-events: auto";
                         cueElem.innerHTML = vttTextToSimple(cue.text, true);
                         customSubsElem.appendChild(cueElem);
                     }
                 }
                 
                 // Handle secondary track
                 if (trackElem2 && trackElem2.track.activeCues) {
                     for (const cue of trackElem2.track.activeCues) {
                         const cueElem = document.createElement("div");
                         cueElem.style.cssText =
                         "background: rgba(0,0,0,0.8); white-space: pre-wrap; padding: 0.2em 0.3em; margin: 10px auto; width: fit-content; width: -moz-fit-content; pointer-events: auto; color: #ffff00;";
                         cueElem.innerHTML = vttTextToSimple(cue.text, true);
                         customSubsElem.appendChild(cueElem);
                     }
                 }
             }
             
             trackElem.addEventListener("cuechange", updateSubtitles);
             if (trackElem2) {
                 trackElem2.addEventListener("cuechange", updateSubtitles);
             }
             
             const playerElem = document.querySelector(".watch-video");
             if (!playerElem) {
                 throw new Error("Couldn't find player element to append subtitles to");
             }
             playerElem.appendChild(customSubsElem);
             
             updateToggleDisplay();
         }
         
         function removeTrackElem() {
             const trackElem = document.getElementById(TRACK_ELEM_ID);
             if (trackElem) {
                 trackElem.remove();
             }
             
             const trackElem2 = document.getElementById(TRACK_ELEM_ID + "2");
             if (trackElem2) {
                 trackElem2.remove();
             }
             
             const customSubsElem = document.getElementById(CUSTOM_SUBS_ELEM_ID);
             if (customSubsElem) {
                 customSubsElem.remove();
             }
             
             disableDownloadButton();
         }
         
         // Determine what subs list should be
         if (
             urlMovieId &&
             document.readyState === "complete" &&
             trackListCache.has(urlMovieId)
             ) {
                 targetSubsList = trackListCache.get(urlMovieId);
             } else {
                 targetSubsList = null;
             }
         
         // Reconcile DOM if necessary
         if (targetSubsList !== displayedSubsList) {
             removeSubsList();
             if (targetSubsList) {
                 addSubsList(targetSubsList);
             }
             displayedSubsList = targetSubsList;
         }
         
         // Determine what subs blobs should be
         const videoElem = document.querySelector("video");
         let targetTrackBlob = null;
         let targetTrackBlob2 = null;
         
         if (urlMovieId && videoElem) {
             if (selectedTrackId) {
                 const cacheKey = urlMovieId + "/" + selectedTrackId;
                 if (webvttCache.has(cacheKey)) {
                     targetTrackBlob = webvttCache.get(cacheKey);
                 }
             }
             
             if (selectedTrackId2) {
                 const cacheKey2 = urlMovieId + "/" + selectedTrackId2;
                 if (webvttCache.has(cacheKey2)) {
                     targetTrackBlob2 = webvttCache.get(cacheKey2);
                 }
             }
         }
         
         // Reconcile DOM if necessary
         if (
             targetTrackBlob !== displayedTrackBlob ||
             targetTrackBlob2 !== displayedTrackBlob2
             ) {
                 removeTrackElem();
                 
                 if (targetTrackBlob || targetTrackBlob2) {
                     const languageCode = selectedTrackId
                     ? getSelectedTrackInfo().language
                     : null;
                     const languageCode2 = selectedTrackId2
                     ? getSelectedTrackInfo2().language
                     : null;
                     addTrackElem(
                                  videoElem,
                                  targetTrackBlob,
                                  targetTrackBlob2,
                                  languageCode,
                                  languageCode2
                                  );
                 }
                 
                 displayedTrackBlob = targetTrackBlob;
                 displayedTrackBlob2 = targetTrackBlob2;
             }
     }
     
     function isSubtitlesProperty(key, value) {
         return (key === "profiles" || value.some((item) => NETFLIX_PROFILES.includes(item)));
     }
     
     function findSubtitlesProperty(obj) {
         for (let key in obj) {
             let value = obj[key];
             if (Array.isArray(value)) {
                 if (isSubtitlesProperty(key, value)) {
                     return value;
                 }
             }
             if (typeof value === "object") {
                 const prop = findSubtitlesProperty(value);
                 if (prop) {
                     return prop;
                 }
             }
         }
         return null;
     }
     
     const originalStringify = JSON.stringify;
     JSON.stringify = function (value) {
         // Don't hardcode property names here because Netflix
         // changes them a lot; search instead
         let prop = findSubtitlesProperty(value);
         if (prop) {
             prop.unshift(WEBVTT_FMT);
         }
         return originalStringify.apply(this, arguments);
     };
     
     const originalParse = JSON.parse;
     JSON.parse = function () {
         const value = originalParse.apply(this, arguments);
         if (
             value &&
             value.result &&
             value.result.movieId &&
             value.result.timedtexttracks
             ) {
                 // console.log('parse', value);
                 extractMovieTextTracks(value.result);
             }
         return value;
     };
     
     // Poll periodically to see if current movie has changed
     setInterval(function () {
         let videoId;
         const videoIdElem = document.querySelector("*[data-videoid]");
         if (videoIdElem) {
             const dsetIdStr = videoIdElem.dataset.videoid;
             if (dsetIdStr) {
                 videoId = +dsetIdStr;
             }
         }
         
         urlMovieId = videoId;
         if (!urlMovieId) {
             selectedTrackId = null;
         }
         
         renderAndReconcile();
     }, POLL_INTERVAL_MS);
     
     // ... existing code ...
     
    document.body.addEventListener("keydown", function (e) {
        // Only handle unmodified keypresses
        if (e.altKey || e.ctrlKey || e.metaKey) return;
        
        switch (e.key.toLowerCase()) {
            case "c": {
                const subsElem = document.getElementById(CUSTOM_SUBS_ELEM_ID);
                if (subsElem) {
                    const pieces = [];
                    for (const child of [...subsElem.children]) {
                        pieces.push(child.textContent); // copy as plain text
                    }
                    const text = pieces.join("\n");
                    navigator.clipboard.writeText(text);
                }
                break;
            }
            case "s": {
                const el = document.getElementById(TOGGLE_DISPLAY_BUTTON_ID);
                if (el) {
                    el.click();
                }
                break;
            }
            case "a": {
                const trackElem = document.getElementById(TRACK_ELEM_ID);
                const videoPlayer =
                netflix?.appContext?.state?.playerApp?.getAPI?.()?.videoPlayer;
                const player = videoPlayer?.getVideoPlayerBySessionId(
                                                                      videoPlayer.getAllPlayerSessionIds()[0]
                                                                      );
                
                if (trackElem?.track?.cues && player) {
                    const currentTime = player.getCurrentTime() / 1000; // Netflix uses milliseconds
                    let targetCue = null;
                    let previousCue = null;
                    
                    // Find the current cue first
                    for (const cue of trackElem.track.cues) {
                        if (cue.startTime > currentTime) {
                            break;
                        }
                        previousCue = cue;
                    }
                    
                    // If we found the current cue, look for the one before it
                    if (previousCue) {
                        for (let i = trackElem.track.cues.length - 1; i >= 0; i--) {
                            const cue = trackElem.track.cues[i];
                            if (cue.startTime < previousCue.startTime) {
                                targetCue = cue;
                                break;
                            }
                        }
                    }
                    
                    // If we found a target cue, seek to it
                    if (targetCue) {
                        player.seek(targetCue.startTime * 1000);
                    }
                }
                break;
            }
            case "d": {
                const trackElem = document.getElementById(TRACK_ELEM_ID);
                const videoPlayer =
                netflix?.appContext?.state?.playerApp?.getAPI?.()?.videoPlayer;
                const player = videoPlayer?.getVideoPlayerBySessionId(
                                                                      videoPlayer.getAllPlayerSessionIds()[0]
                                                                      );
                
                if (trackElem?.track?.cues && player) {
                    const currentTime = player.getCurrentTime() / 1000; // Netflix uses milliseconds
                    for (const cue of trackElem.track.cues) {
                        if (cue.startTime > currentTime) {
                            player.seek(cue.startTime * 1000); // Convert back to milliseconds
                            break;
                        }
                    }
                }
                break;
            }
        }
    }, false);
     
     // ... existing code ...
     
     let hideSubsListTimeout;
     function hideSubsListTimerFunc() {
         const el = document.getElementById(SUBS_LIST_ELEM_ID);
         if (el) {
             el.style.display = "none";
         }
         hideSubsListTimeout = null;
     }
    
    document.body.addEventListener("mousemove", function (e) {
        // If there are any popups, make sure our subs don't block mouse events
        const subsElem = document.getElementById(CUSTOM_SUBS_ELEM_ID);
        if (subsElem) {
            const popup = document.querySelector(".popup-content");
            if (popup) {
                subsElem.style.display = "none";
            } else {
                subsElem.style.display = "block";
            }
        }
        
        // Show subs list and update timer to hide it
        const subsListElem = document.getElementById(SUBS_LIST_ELEM_ID);
        if (subsListElem) {
            subsListElem.style.display = "block";
        }
        if (hideSubsListTimeout) {
            clearTimeout(hideSubsListTimeout);
        }
        hideSubsListTimeout = setTimeout(hideSubsListTimerFunc, 3000);
    }, false);
})();
