#!/usr/bin/env hy

(require [hy.extra.anaphoric [*]]
         [helpers [*]]
         )

(import os
        logging
        sys
        argparse
        time
        json
        pprint
        dns

        [retry [retry]]
        [helpers [*]]
        [dns.resolver [Resolver]]
        [dns.rdatatype :as rtype]
        asyncio
        )

(with-decorator (retry Exception :delay 5 :backoff 4 :max-delay 120)
  (defn query-rs
    [resolver domain &optional [rdtype "a"]]
    (try (resolver.resolve domain :rdtype rdtype)
         (except [e [dns.exception.Timeout
                     dns.resolver.NoNameservers
                     dns.resolver.NXDOMAIN
                     dns.resolver.NoAnswer
                     ]]
           None
           #_(logging.error "error valid domain? %s" e)))))

(defn parse-answer
  [r]
  {"name" (-> (str r.qname)
              (.rstrip "."))
   "type" (rtype.to-text r.rdtype)
   "expiration" r.expiration
   "canonical-name" (-> (str r.canonical-name)
                        (.rstrip "."))
   "result" (lfor a r.rrset
                  (str a))})

(defn get-domain-records
  [resolver domain &optional [types ["a" "aaaa" "mx" "ns" "txt" "cname" "soa"]]]
  (->> types
       (pmap #%(query-rs resolver domain :rdtype %1))
       (filter identity)
       (map parse-answer)
       list))

(defn get-records
  [domains &optional resolver [timeout 30] types]
  (setv rsv (if resolver
                (doto (Resolver :configure False)
                      (setattr "nameservers" proxies))
                (Resolver)))
  (setv rsv.lifetime timeout)
  (->> domains
       (map #%(get-domain-records rsv %1
                                  #** (if types
                                          {"types" types}
                                          {})))
       (filter identity)
       unpack-iterable
       concat))

(comment
  (setv rsv (Resolver))

  (pprint.pprint (get-domain-records rsv "bing.com"))
  )

(defn valid-rdtype?
  [rdt]
  (try (rtype.from-text rdt)
       True
       (except [e dns.rdatatype.UnknownRdatatype]
         False)))

(defn rdtypes
  [rs]
  (->2> (rs.split ",")
        (map str.strip)
        (lfor r
         (if (valid-rdtype? r)
             r
             (raise (argparse.ArgumentTypeError f"{r} not valid Rdatatype"))))))

(defmain [&rest args]
  (logging.basicConfig :level logging.INFO
                       :style "{"
                       :format "{asctime} [{levelname}] {filename}({funcName})[{lineno}] {message}")

  (setv opts (parse-args [["-r" "--resolvers"
                           :type (argparse.FileType "r")
                           :help "包含dns解析服务器列表的文件,如果为空，则使用系统的dns解析服务器"]
                          ["-d" "--domains"
                           :nargs "?"
                           :type (argparse.FileType "r")
                           :default sys.stdin
                           :help "域名列表文件"]
                          ["-t" "--types"
                           :type rdtypes
                           :default "a,aaaa,mx,ns,txt,cname,soa"
                           :help "要查询的record类型,','分割 (default: %(default)s)"]
                          ["-e" "--timeout"
                           :type int
                           :default 60
                           :help "记录查询超时时间 (default: %(default)s)"]
                          ["-o" "--output"
                           :nargs "?"
                           :type (argparse.FileType "w")
                           :default sys.stdout
                           :help "输出文件"]
                          ["domain" :nargs "*" :help "域名列表"]
                          ]
                         (rest args)
                         :description "检测域名的所有查询记录"))
  (setv resolver (when opts.resolvers
                   (read-valid-lines opts.resolvers)))
  (setv domains  (if (opts.domains.isatty)
                     (if opts.domain
                         opts.domain
                         (read-valid-lines opts.domains))
                     (+ opts.domain
                        (read-valid-lines opts.domains))))
  (-> (get-records domains
                   :resolver resolver
                   :types opts.types
                   :timeout opts.timeout)
      (json.dumps :indent 2 :sort-keys True)
      (opts.output.write))

  (logging.info "exit.")
  )