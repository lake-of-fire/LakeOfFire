import Foundation
import SwiftUIWebView
//import WebKit

public struct YoutubeCaptionsUserScript {
    public static let userScript = WebViewUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page, allowedDomains: Set(["youtube.com"]))
    
    // From: https://github.com/1c7/Youtube-Auto-Subtitle-Download/blob/master/Youtube 下载自动字幕的字词级文件/Tampermonkey.js
    // ==UserScript==
    // @name           Youtube 下载自动字幕 (字词级) v6
    // @include        https://*youtube.com/*
    // @author         Cheng Zheng
    // @require        https://code.jquery.com/jquery-1.12.4.min.js
    // @version        6
    // @grant GM_xmlhttpRequest
    // @namespace https://greasyfork.org/users/5711
    // @description   （下载 .json 文件）字词级字幕仅适用于自动字幕（也就是机器用语音转文字识别出来的字幕）（完整字幕没有字词级的）下载字词级的意义是方便分句。可下载两种格式：原版 (&fmt=json3 从 Youtube 获取的原样返回) 和简化版 {startTime: "开始时间(毫秒)", endTime: "结束时间(毫秒)", text: "文字"}。 json 格式不可配合视频直接播放，需要其他软件进行进一步处理（把词拼成句子，转成 srt 格式）
    // @license  MIT
    // ==/UserScript==
    static private let script = #"""
(function () {
    // 初始化
    var first_load = true; // indicate if first load this webpage or not
    unsafeWindow.caption_array = []; // store all subtitle

    $(document).ready(function () {
        make_sure_it_load_properly_before_continue();
    });

    async function wait_until_element_exists(element_identifier) {
        var retry_count = 0;
        var RETRY_LIMIT = 120;
        return new Promise(function (resolve, reject) {
            var intervalID = setInterval(function () {
                try {
                    var element = document.querySelector(element_identifier);
                    if (element != null) {
                        resolve(true);
                    } else {
                        retry_count = retry_count + 1;
                        // console.log(`重试次数 ${retry_count}`);
                        if (retry_count > RETRY_LIMIT) {
                            clearInterval(intervalID);
                            reject(false);
                        }
                    }
                } catch (error) {
                    reject(false);
                }
            }, 300);
        });
    }

    async function make_sure_it_load_properly_before_continue() {
        var id = new_Youtube_2022_UI_element_identifier();
        var result = await wait_until_element_exists(id);
        if (result) {
            postMessage();
        }
    }

    // trigger when loading new page
    // (actually this would also trigger when first loading, that's not what we want, that's why we need to use firsr_load === false)
    // (new Material design version would trigger this "yt-navigate-finish" event. old version would not.)
    var body = document.getElementsByTagName("body")[0];
    body.addEventListener("yt-navigate-finish", function (event) {
        if (current_page_is_video_page() === false) {
            return;
        }
        unsafeWindow.caption_array = []; // clean up (important, otherwise would have more and more item and cause error)

        // if use click to another page, init again to get correct subtitle
        if (first_load === false) {
            postMessage();
        }
    });


    //https://stackoverflow.com/questions/11582512/how-to-get-url-parameters-with-javascript/11582513#11582513
    function getURLParameter(name) {
        return (
            decodeURIComponent(
                (new RegExp('[?|&]' + name + '=' + '([^&;]+?)(&|#|;|$)').exec(
                    location.search
                ) || [null, ''])[1].replace(/\+/g, '%20')
            ) || null
        )
    }

    // trigger when loading new page
    // (old version would trigger "spfdone" event. new Material design version not sure yet.)
    window.addEventListener("spfdone", function (e) {
        if (current_page_is_video_page()) {
            //remove_subtitle_download_button();
            var checkExist = setInterval(function () {
                if ($('#watch7-headline').length) {
                    postMessage();
                    clearInterval(checkExist);
                }
            }, 330);
        }
    });

    // return true / false
    // Detect [new version UI(material design)] OR [old version UI]
    // I tested this, accurated.
    function new_material_design_version() {
        var old_title_element = document.getElementById('watch7-headline');
        if (old_title_element) {
            return false;
        } else {
            return true;
        }
    }

    // return true / false
    function current_page_is_video_page() {
        return get_url_video_id() !== null;
    }

    // return string like "RW1ChiWyiZQ",  from "https://www.youtube.com/watch?v=RW1ChiWyiZQ"
    // or null
    function get_url_video_id() {
        return getURLParameter('v');
    }

    function get_file_name(x) {
        var suffix = 'json'
        var method_3 = `(${x})${get_title()}_video_id_${get_video_id()}.${suffix}`;
        return method_3
    }

    function parse_youtube_XML_to_JSON(json) {
        var final_result = [];

        // var template_example = {
        //   startTime: null,
        //   endTime: null,
        //   text: null
        // }

        var events = json.events

        for (var i = 0; i < events.length; i++) {
            var event = events[i];

            // 对于内容(segs)为空的，直接跳过
            if (event.segs == undefined) {
                continue
            }

            // aAppend 就是只有一个 \n
            if (event.aAppend != undefined) {
                continue
            }

            var startTime = null
            var endTime = event.tStartMs + event.dDurationMs;
            var text = null;

            var segs = event.segs
            for (var j = 0; j < segs.length; j++) {
                var seg = segs[j];
                if (seg.tOffsetMs) {
                    startTime = event.tStartMs + seg.tOffsetMs
                } else {
                    startTime = event.tStartMs
                }
                text = seg.utf8;
                var one = {
                    startTime: startTime,
                    endTime: endTime,
                    text: text,
                }
                final_result.push(one);
            }
        }
        return final_result;
    }

    /*
    function get_title() {
        return ytplayer.config.args.title;
    }
    function get_video_id() {
        return ytplayer.config.args.video_id;
    }
    */

    // Usage: var result = await get(url)
    function get(url) {
        return $.ajax({
            url: url,
            type: 'get',
            success: function (r) {
                return r
            },
            fail: function (error) {
                return error
            }
        });
    }

    // 我们用这个元素判断是不是 2022 年新 UI 。
    // return Element;
    function new_Youtube_2022_UI_element() {
        return document.querySelector(new_Youtube_2022_UI_element_identifier());
    }

    function new_Youtube_2022_UI_element_identifier() {
        var document_querySelector = "#owner.item.style-scope.ytd-watch-metadata";
        return document_querySelector;
    }
})();

















  // Trigger when user select <option>
  async function download_subtitle(selector) {
    console.log('进入download_subtitle')
    // if user select first <option>
    // we just return, do nothing.
    if (selector.selectedIndex == 0) {
      return
    }

    // 核心概念
    // 对于完整字幕而言，英文和中文的时间轴是一致的，只需要一行行的 match 即可

    // 但是对于自动字幕就不是这样了，"自动字幕的英文"只能拿到一个个单词的开始时间和结束时间
    // "自动字幕的中文"只能拿到一个个句子
    // 现在的做法是，先拿到中文，处理成 SRT 格式，
    // 然后去拿英文，然后把英文的每个词，拿去和中文的每个句子的开始时间和结束时间进行对比
    // 如果"英文单词的开始时间"在"中文句子的开始-结束时间"区间内，那么认为这个英文单词属于这一句中文

    // 2021-8-11 更新
    // 自动字幕的改了，和完整字幕一样了。

    var caption = caption_array[selector.selectedIndex - 1] // because first <option> is for display, so index-1
    var lang_code = caption.lang_code
    var lang_name = caption.lang_name

    // 初始化2个变量
    var origin_url = null
    var translated_url = null


    var result = null;
    var filename = null; // 保存文件名

    // if user choose auto subtitle
    if (caption.lang_code == 'AUTO-original') {
      result = await get_auto_subtitle();
      filename = get_file_name(`原版 JSON-${get_auto_subtitle_name()}`);
      downloadString(JSON.stringify(result), "text/plain", filename);
    }
    // if user choose auto subtitle
    // 如果用户选的是自动字幕
    if (caption.lang_code == 'AUTO') {
      origin_url = get_auto_subtitle_xml_url()
      translated_url = origin_url + '&tlang=zh-Hans'
      var translated_xml = await get(translated_url)
      var translated_srt = parse_youtube_XML_to_object_list(translated_xml)
      var srt_string = object_array_to_SRT_string(translated_srt)
      var title = get_file_name(lang_name)
      downloadString(srt_string, 'text/plain', title)

      // after download, select first <option>
      selector.options[0].selected = true
      return // 别忘了 return
    }

    // 如果用户选的是完整字幕
    origin_url = await get_closed_subtitle_url(lang_code)
    translated_url = origin_url + '&tlang=zh-Hans'

    var original_xml = await get(origin_url)
    var translated_xml = await get(translated_url)

    // 根据时间轴融合这俩
    var original_srt = parse_youtube_XML_to_object_list(original_xml)
    var translated_srt = parse_youtube_XML_to_object_list(translated_xml)
    //var dual_language_srt = merge_srt(original_srt, translated_srt)

    var srt_string = object_array_to_SRT_string(dual_language_srt)
    var title = get_file_name(lang_name)
    downloadString(srt_string, 'text/plain', title)

    // after download, select first <option>
    selector.options[0].selected = true
  }

  // Detect if "auto subtitle" and "closed subtitle" exist
  // And add <option> into <select>
  // 加载语言列表
  function load_language_list(select) {
    // auto
    var auto_subtitle_exist = false // 自动字幕是否存在(默认 false)

    // closed
    var closed_subtitle_exist = false

    // get auto subtitle
    var auto_subtitle_url = get_auto_subtitle_xml_url()
    if (auto_subtitle_url != false) {
      auto_subtitle_exist = true
    }

    // if there are "closed" subtitle?
    var captionTracks = get_captionTracks()
    if (
      captionTracks != undefined &&
      typeof captionTracks === 'object' &&
      captionTracks.length > 0
    ) {
      closed_subtitle_exist = true
    }

    // if no subtitle at all, just say no and stop
    if (auto_subtitle_exist == false && closed_subtitle_exist == false) {
      select.options[0].textContent = NO_SUBTITLE
      disable_download_button()
      return false
    }

    // if at least one type of subtitle exist
    select.options[0].textContent = HAVE_SUBTITLE
    select.disabled = false

    var option = null // for <option>
    var caption_info = null // for our custom object

    // 自动字幕
    if (auto_subtitle_exist) {
      var auto_sub_name = get_auto_subtitle_name()
      var lang_name = `${auto_sub_name} 翻译的中文`
      caption_info = {
        lang_code: 'AUTO', // later we use this to know if it's auto subtitle
        lang_name: lang_name, // for display only
      }
      caption_array.push(caption_info)

      option = document.createElement('option')
      option.textContent = caption_info.lang_name
      select.appendChild(option)
    }

    // if closed_subtitle_exist
    if (closed_subtitle_exist) {
      for (var i = 0, il = captionTracks.length; i < il; i++) {
        var caption = captionTracks[i]
        if (caption.kind == 'asr') {
          continue
        }
        let lang_code = caption.languageCode
        let lang_translated = caption.name.simpleText
        var lang_name = `中文 + ${lang_code_to_local_name(
          lang_code,
          lang_translated
        )}`
        caption_info = {
          lang_code: lang_code, // for AJAX request
          lang_name: lang_name, // display to user
        }
        caption_array.push(caption_info)
        // 注意这里是加到 caption_array, 一个全局变量, 待会要靠它来下载
        option = document.createElement('option')
        option.textContent = caption_info.lang_name
        select.appendChild(option)
      }
    }
  }

  // 禁用下载按钮
  function disable_download_button() {
    $(HASH_BUTTON_ID)
      .css('border', '#95a5a6')
      .css('cursor', 'not-allowed')
      .css('background-color', '#95a5a6')
    $('#captions_selector')
      .css('border', '#95a5a6')
      .css('cursor', 'not-allowed')
      .css('background-color', '#95a5a6')

    if (new_material_design_version()) {
      $(HASH_BUTTON_ID).css('padding', '6px')
    } else {
      $(HASH_BUTTON_ID).css('padding', '5px')
    }
  }

  // 处理时间. 比如 start="671.33"  start="37.64"  start="12" start="23.029"
  // 处理成 srt 时间, 比如 00:00:00,090    00:00:08,460    00:10:29,350
  function process_time(s) {
    s = s.toFixed(3)
    // 超棒的函数, 不论是整数还是小数都给弄成3位小数形式
    // 举个柚子:
    // 671.33 -> 671.330
    // 671 -> 671.000
    // 注意函数会四舍五入. 具体读文档

    var array = s.split('.')
    // 把开始时间根据句号分割
    // 671.330 会分割成数组: [671, 330]

    var Hour = 0
    var Minute = 0
    var Second = array[0] // 671
    var MilliSecond = array[1] // 330
    // 先声明下变量, 待会把这几个拼好就行了

    // 我们来处理秒数.  把"分钟"和"小时"除出来
    if (Second >= 60) {
      Minute = Math.floor(Second / 60)
      Second = Second - Minute * 60
      // 把 秒 拆成 分钟和秒, 比如121秒, 拆成2分钟1秒

      Hour = Math.floor(Minute / 60)
      Minute = Minute - Hour * 60
      // 把 分钟 拆成 小时和分钟, 比如700分钟, 拆成11小时40分钟
    }
    // 分钟，如果位数不够两位就变成两位，下面两个if语句的作用也是一样。
    if (Minute < 10) {
      Minute = '0' + Minute
    }
    // 小时
    if (Hour < 10) {
      Hour = '0' + Hour
    }
    // 秒
    if (Second < 10) {
      Second = '0' + Second
    }
    return Hour + ':' + Minute + ':' + Second + ',' + MilliSecond
  }

  // Copy from: https://gist.github.com/danallison/3ec9d5314788b337b682
  // Thanks! https://github.com/danallison
  // Work in Chrome 66
  // Test passed: 2018-5-19
  function downloadString(text, fileType, fileName) {
    var blob = new Blob([text], {
      type: fileType,
    })
    var a = document.createElement('a')
    a.download = fileName
    a.href = URL.createObjectURL(blob)
    a.dataset.downloadurl = [fileType, a.download, a.href].join(':')
    a.style.display = 'none'
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    setTimeout(function () {
      URL.revokeObjectURL(a.href)
    }, 1500)
  }

    /*
  // https://css-tricks.com/snippets/javascript/unescape-html-in-js/
  // turn HTML entity back to text, example: &quot; should be "
  function htmlDecode(input) {
    var e = document.createElement('div')
    e.class =
      'dummy-element-for-tampermonkey-Youtube-cn-other-subtitle-script-to-decode-html-entity-2021-8-11'
    e.innerHTML = input
    return e.childNodes.length === 0 ? '' : e.childNodes[0].nodeValue
  }
  */

  // 获得自动字幕的地址
  // return URL or null;
  // later we can send a AJAX and get XML subtitle
  // 例子输出: https://www.youtube.com/api/timedtext?v=JfBZfnkg1uM&asr_langs=de,en,es,fr,it,ja,ko,nl,pt,ru&caps=asr&exp=xftt,xctw&xorp=true&xoaf=5&hl=zh-CN&ip=0.0.0.0&ipbits=0&expire=1628691971&sparams=ip,ipbits,expire,v,asr_langs,caps,exp,xorp,xoaf&signature=55984444BD75E34DB9FE809058CCF7DE5B1AB3B5.193DC32A1E0183D8D627D229C9C111E174FF56FF&key=yt8&kind=asr&lang=en
  /*
    如果直接访问这个地址，里面的格式是 XML，比如
    <transcript>
      <text start="0.589" dur="6.121">hello in this video I would like to</text>
      <text start="3.6" dur="5.88">share what I&#39;ve learned about setting up</text>
      <text start="6.71" dur="5.08">shadows and shadow casting and shadow</text>
      <text start="9.48" dur="5.6">occlusion and stuff like that in a</text>
    </transcript>
  */
  function get_auto_subtitle_xml_url() {
    try {
      var captionTracks = get_captionTracks()
      for (var index in captionTracks) {
        var caption = captionTracks[index]
        if (typeof caption.kind === 'string' && caption.kind == 'asr') {
          return captionTracks[index].baseUrl
        }
        // ASR – A caption track generated using automatic speech recognition.
        // https://developers.google.com/youtube/v3/docs/captions
      }
    } catch (error) {
      return false
    }
  }

  // Input: lang_code like 'en'
  // Output: URL (String)
  async function get_closed_subtitle_url(lang_code) {
    try {
      var captionTracks = get_captionTracks()
      for (var index in captionTracks) {
        var caption = captionTracks[index]
        if (caption.languageCode === lang_code && caption.kind != 'asr') {
          var url = captionTracks[index].baseUrl
          return url
        }
      }
    } catch (error) {
      console.log(error)
      return false
    }
  }

  // return "English (auto-generated)" or a default name;
  function get_auto_subtitle_name() {
    try {
      var captionTracks = get_captionTracks()
      for (var index in captionTracks) {
        var caption = captionTracks[index]
        if (typeof caption.kind === 'string' && caption.kind == 'asr') {
          return captionTracks[index].name.simpleText
        }
      }
      return 'Auto Subtitle'
    } catch (error) {
      return 'Auto Subtitle'
    }
  }

  function get_captionTracks() {
    let data = document.getElementsByTagName('ytd-app')[0].data.playerResponse
    var captionTracks =
      data?.captions?.playerCaptionsTracklistRenderer?.captionTracks
    return captionTracks
  }

  // Input a language code, output that language name in current locale
  // 如果当前语言是中文简体, Input: "de" Output: 德语
  // if current locale is English(US), Input: "de" Output: "Germany"
  function lang_code_to_local_name(languageCode, fallback_name) {
    try {
      var captionTracks = get_captionTracks()
      for (var i in captionTracks) {
        var caption = captionTracks[i]
        if (caption.languageCode === languageCode) {
          let simpleText = captionTracks[i].name.simpleText
          if (simpleText) {
            return simpleText
          } else {
            return fallback_name
          }
        }
      }
    } catch (error) {
      return fallback_name
    }
  }

  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

  // 等待一个元素存在
  // https://stackoverflow.com/questions/5525071/how-to-wait-until-an-element-exists
  function waitForElement(selector) {
    return new Promise((resolve) => {
      if (document.querySelector(selector)) {
        return resolve(document.querySelector(selector))
      }

      const observer = new MutationObserver((mutations) => {
        if (document.querySelector(selector)) {
          resolve(document.querySelector(selector))
          observer.disconnect()
        }
      })

      observer.observe(document.body, {
        childList: true,
        subtree: true,
      })
    })
  }

  function init() {
    inject_our_script()
    first_load = false
  }

  async function main() {
    await waitForElement(anchor_element)
    init()
  }

  setTimeout(main, 2000);
})()
"""#
}
