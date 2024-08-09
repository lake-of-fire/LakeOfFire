//import Foundation
//import SwiftUIWebView
////import WebKit
//
//public struct YoutubeAdBlockUserScript {
//    public static let userScript = WebViewUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page, allowedDomains: Set(["youtube.com"]))
//    
//    // From: https://gist.github.com/K-mikaZ/c5dfd575b71f2ae6535013103d74c2f7
//    //
//    // ==UserScript==
//    // @name         [⚙][addon] You(Tube)™ Adblock
//    // @namespace    tag:github.com,2022:K-mik@Z:YouTubeAdblock:EnoughWithTheAds:TryToTakeOverTheWorld
//    // @version      0.1
//    // @description  enough with the ads!
//    // @copyright    2022+, K-mik@Z
//    // @author       K-mik@Z <cool2larime@yahoo.fr> (https://github.com/K-mikaZ)
//    // @match        https://*.youtube.com/*
//    // @grant        none
//    // @run-at       document-start
//    // @icon         data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAq0lEQVQ4jaWT0Q2DMAxEXyIGYAMygkdgBTZgRDaAETpC2CAbXD+giKoJbYklK4niO8tn20mixnwVGmiOm3MtYPurL8Qv+/lASgBIQjAK9KePkkBgN8AvNw+ECgnMn+r+tBihL8kBQLjuQtfBPMM0QQjZkN/a2LbFr2uCdYVh2MqIMRvSAI8igRmkdJUieiBPDd/AsA1U3SC5Y5neR9mAnHLLKXMCTgQ3rXobnzl8hRUj722/AAAAAElFTkSuQmCC
//    // @icon64       data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAAe1BMVEVHcEymAACFhYXkAAC/AADyAADTAAD/////Ly//AwPhBgbxAAAmAAD5AADxAADJAADVBATaDw+BAADTAgL/LCzWAADhCAjfGhr/KCjnAAD0AADOAAD/AAD/////9/f/7+//e3v/UFD/vr7/qan/PT3/39//kJD/Kir/zc0Q/tNHAAAAHHRSTlMALQOZg+HKD8j9S+wQ88ttWX4fO6+0imqYqbniBuNvagAAAZNJREFUWIXtlt1ygjAQhTdEaBOSQEQBNVGrrfX9n7ABRlvR/EhueuGZYRgg52MTluwCvPTSv1LCEKpo00jZtovF4n0sc69ta9k0Ja0QYsnIPpdrkeZEKdUdv6erhmvSn3ieCoHpXztWT4uotLz4Wfq8v1cz+FE+0a/UEMNqsl/l/QJM9w8hFDEAHDcDpQSDRMQA0jnMp37DXhxFAggFxG0P9+N0fqQSKuuw7TmAUEBpB2h99CJqRxoYgD5/eADYAzBBfDoBK5h5AHq3dwGWfoDWX455BAH09mgdlAUBHPMIBWh9eLyYGdSBgN3p4SARGoElgNAp2L9DGOD0bR0UAjjY7V0e+FLZnYhegEkh4vwjMZQugCuJLwBqfYEv+l4SKuuWdvC+XnU7UkRl7FTG7soVsKjCkiOAdUwApjKBjIlgbYprFQOQXYMQs4qsA9Dp/npokiYT6kubVk5LpqvfSIo8pBZfRbjA7KZVZYgWM7zMsk3O+V2f2nsI4TzdZNkSzwpa3drHfXOSvN3J3HR32y+9FKEfw10c+oXU9S4AAAAASUVORK5CYII=
//    // ==/UserScript==
//    static private let script = #"""
//if (window.Oxdeadbeef === true) return;
//window.Oxdeadbeef = true;
//
//
//let prune = window.prune || {};
//
//window.prune = {
//    annotations: true
//    , cards: true
//    , endscreen: true
//    // chatBox: false /** in case of deleting chat box **/
//    // https://greasyfork.org/fr/scripts/416957-no-youtube-chat/code
//};
//
//let personalized = window.personalized || {};
//
//window.personalized = {
//    theaterMode: false
//};
//
//
//// Detect the type of YouTube page loaded
//// var isWatchPage = location.href.indexOf("https://www.youtube.com/watch?") === 0;
//
//
//(function() {
//    /** config handler **/
//
//    // FIXME: Works only when page reload after start from homepage
//
//    var ytInitialPlayerResponse = null,
//        ytInitialData = null,
//        ytplayer = null;
//
//
//    /** how to conditionally add something to an object?
//     *  https://stackoverflow.com/questions/11704267/in-javascript-how-to-conditionally-add-a-member-to-an-object **/
//
//    function setter_ytInitialPlayerResponse(data) {
//        /** @example: playerConfig: { audioConfig: { enablePerFormatLoudness: true } }, **/
//
//        /* eslint-disable no-multi-spaces */
//        ytInitialPlayerResponse = {
//            ...data                                                          /** Default data **/
//            , adPlacements: []                                               /** Prune ads **/
//
//            /** cosmetic rules **/
//            , ...((true == window.prune.annotations) && { annotations: [] }) /** Prune annotations if desired **/
//            , ...((true == window.prune.cards)       && { cards: [] })       /** Prune cards if desired **/
//            , ...((true == window.prune.endscreen)   && { endscreen: [] })   /** Prune endscreen if desired **/
//            // , "messages": { 0: { "youThereRenderer": [] } },              /** (are you there popup) or perhaps "messages": [] **/
//            , playerAds: []
//        }
//        /* eslint-enable no-multi-spaces */
//    }
//
//
//    /** https://www.reddit.com/r/uBlockOrigin/comments/tcswua/tip_noncosmetic_filters_to_remove_junk_from/ **/
//
//    function setter_ytInitialData(data) {
//        /* eslint-disable no-multi-spaces */
//        ytInitialData = {
//            contents: {
//                twoColumnBrowseResultsRenderer: {
//                    tabs: {
//                        0: {
//                            tabRenderer: {
//                                content: {
//                                    richGridRenderer: {
//                                        /** FIXME: seems not working,
//                                         * even bannerPromoRenderer **/
//                                        masthead: []                                 /** Prune ads - contains only bannerPromoRenderer **/
//                                    }}}}}
//                }
//                , twoColumnWatchNextResults: {
//                    secondaryResults: {
//                        secondaryResults: {
//                            results: {
//                                0: {
//                                    promotedSparklesWebRenderer: []                   /** Prune ads **/
//                                    , compactPromotedVideoRenderer: []                /** Prune ads **/
//                                }}}}
//                }
//                , twoColumnSearchResultsRenderer: {
//                    primaryContents: {
//                        sectionListRenderer: {
//                            contents: {
//                                0: {
//                                    itemSectionRenderer: {
//                                        contents: {
//                                            0: {
//                                                promotedSparklesTextSearchRenderer: [] /** Prune ads **/
//                                            }}}}}}}
//                }
//            }
//            ,...data                                                                   /** Default data **/
//            , engagementPanels: []                                                     /** IN TEST: ??? **/
//
//            /** cosmetic rules - !! ATTENTION: this one block play next **/
//            // , ...((true == window.prune.endscreen) && {
//            //     playerOverlays: { playerOverlayRenderer: { endScreen: [] } }
//            // })
//        }
//        /* eslint-enable no-multi-spaces */
//    }
//
//
//    Object.defineProperties(window, {
//        /** https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object/defineProperty **/
//        /** https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/Object/defineProperties **/
//
//        'ytInitialPlayerResponse': {
//            get: ()=> { return ytInitialPlayerResponse; }
//            , set: setter_ytInitialPlayerResponse
//            , configurable: true
//        }
//
//        , 'ytInitialData': {
//            get: ()=> { return ytInitialData; }
//            , set: setter_ytInitialData
//            , configurable: true
//        }
//
//    });
//
//})();
//
//
//// FETCH POLYFILL
//(function() {
//    const {fetch: origFetch} = window;
//    window.fetch = async (...args) => {
//        const response = await origFetch(...args);
//
//        if (response.url.includes('/youtubei/v1/player')) {
//            const text = () =>
//                response
//                    .clone()
//                    .text()
//                    .then((data) => data.replace(/adPlacements/, 'odPlacement'));
//
//            response.text = text;
//            return response;
//        }
//        return response;
//    };
//})();
//"""#
//}
