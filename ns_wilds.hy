#!/usr/bin/env hy

(import sys)
(sys.path.append ".")
(require [hy.extra.anaphoric [*]]
         [helpers [*]]
         )

(import os
        logging
        sys
        argparse
        time
        asyncio

        [ns-valid [filter-valid-domain]]
        [retry [retry]]
        [helpers [*]]
        [publicsuffix2 [get-public-suffix PublicSuffixList]]
        )

(setv psl (PublicSuffixList))

(defn/a get-domains
  [domain-top-name &optional resolver]
  (-> (map #%(.format "{}.{}" domain-top-name %1) psl.tlds)
      (filter-valid-domain :proxies resolver)
      await))

(defn/a get-wildcards-domains
  [wd-domains &optional resolver]
  (-> wd-domains
      (->> (map #%(-> (.split %1 ".")
                      (of -2)
                      (get-domains :resolver resolver)
                      (asyncio.ensure-future))))
      unpack-iterable
      (asyncio.gather :return-exceptions True)
      await
      unpack-iterable
      +))

(defn/a main
  [opts]
  (setv resolver (when opts.resolvers
                   (read-valid-lines opts.resolvers)))
  (setv domains  (if (opts.domains.isatty)
                     opts.domain
                     (+ opts.domain
                        (read-valid-lines opts.domains))))
  (setv by-wild #%(.endswith %1 ".*"))
  (setv [ns wds]
        (-> domains
            (sorted :key by-wild)
            (group-by :key by-wild)
            (->> (map #%(identity
                          [(if (first %1)
                               "wildcards"
                               "normal")
                           (-> (second %1)
                               list)])))
            dict
            (doto print)
            ((juxt #%(->> (of %1 "normal")
                          (map get-public-suffix)
                          list)
                   #%(-> (of %1 "wildcards")
                         (get-wildcards-domains :resolver resolver))))))
  (->> (await wds)
       (+ ns)
       set
       (.join "\n")
       (opts.output.write)))


(comment

  (setv ds (-> (open "./wildd.txt")
               read-valid-lines))

  (setv d2 (->> ds
                (map get-public-suffix)
                list))

  )
(defmain [&rest args]
  (logging.basicConfig :level logging.INFO
                       :style "{"
                       :format "{asctime} [{levelname}] {filename}({funcName})[{lineno}] {message}")

  (setv opts (parse-args [["-r" "--resolvers"
                           :type (argparse.FileType "r")
                           :help "包含dns解析服务器列表的文件"]

                          ["-d" "--domains"
                           :nargs "?"
                           :type (argparse.FileType "r")
                           :default sys.stdin
                           :help "输入的域名，可包含*通配"]
                          ["-o" "--output"
                           :nargs "?"
                           :type (argparse.FileType "w")
                           :default sys.stdout
                           :help "输出合法的一级域名"]
                          ["domain" :nargs "*" :help "要检测的域名"]
                          ]
                         (rest args)
                         :description "过滤，查找合法的一级域名，可以使用*通配域名后缀(tld)"))
  (doto (asyncio.get-event-loop)
        (.run-until-complete (main opts))
        (.close))
  )