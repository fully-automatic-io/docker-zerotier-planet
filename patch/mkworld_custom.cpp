/*
 * ZeroTier One - Network Virtualization Everywhere
 * Copyright (C) 2011-2016  ZeroTier, Inc.  https://www.zerotier.com/
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */


// Legacy: mkworld [-j|-b]. Explicit commands never create signing keys.
#include <stdio.h>
#include <string.h>
#include <algorithm>
#include <stdexcept>
#include <set>
#include <nlohmann/json.hpp>
#include <node/World.hpp>
#include <node/Identity.hpp>
#include <osdep/OSUtils.hpp>
using namespace ZeroTier;
using json = nlohmann::json;

static std::string read(const std::string& p) {
    std::string s;
    if (!OSUtils::readFile(p.c_str(), s)) throw std::runtime_error("Cannot read " + p);
    return s;
}
static void write(const std::string& p, const std::string& s) {
    if (!OSUtils::writeFile(p.c_str(), s)) throw std::runtime_error("Cannot write " + p);
}
static World load(const std::string& p) {
    auto s = read(p);
    if (s.empty() || s.size() > ZT_WORLD_MAX_SERIALIZED_LENGTH) throw std::runtime_error("Invalid planet size");
    Buffer<ZT_WORLD_MAX_SERIALIZED_LENGTH> b(s.data(), s.size());
    World w;
    if (w.deserialize(b, 0) != s.size() || w.type() != World::TYPE_PLANET || w.roots().empty())
        throw std::runtime_error("Invalid planet");
    return w;
}
static json describe(const World& w) {
    json j = {{"id",w.id()}, {"timestamp",w.timestamp()}, {"type","planet"}, {"roots",json::array()}};
    for (const auto& r : w.roots()) {
        char id[ZT_IDENTITY_STRING_BUFFER_LENGTH]; r.identity.toString(false,id);
        json endpoints = json::array();
        for (const auto& ep : r.stableEndpoints) { char ip[64]; ep.toString(ip); endpoints.push_back(ip); }
        j["roots"].push_back({{"identity",id},{"stableEndpoints",endpoints}});
    }
    return j;
}
static std::vector<World::Root> rootsFrom(const json& j) {
    const auto& a = j.at("roots");
    if (!a.is_array() || a.empty() || a.size() > ZT_WORLD_MAX_ROOTS) throw std::runtime_error("Need 1..4 roots");
    std::vector<World::Root> roots;
    std::set<uint64_t> ids;
    for (const auto& item : a) {
        World::Root r;
        r.identity = Identity(item.at("identity").get<std::string>().c_str());
        if (r.identity.hasPrivate() || !r.identity.locallyValidate() || !ids.insert(r.identity.address().toInt()).second)
            throw std::runtime_error("Invalid, private or duplicate identity");
        const auto& eps = item.at("stableEndpoints");
        if (!eps.is_array() || eps.empty() || eps.size() > ZT_WORLD_MAX_STABLE_ENDPOINTS_PER_ROOT)
            throw std::runtime_error("Invalid endpoint count");
        for (const auto& e : eps) {
            const auto text = e.get<std::string>();
            const auto slash = text.rfind('/');
            if (slash == std::string::npos) throw std::runtime_error("Expected IP/port");
            const auto port = text.substr(slash+1);
            if (port.empty() || port.find_first_not_of("0123456789") != std::string::npos ||
                std::stoul(port) == 0 || std::stoul(port) > 65535) throw std::runtime_error("Invalid port");
            InetAddress ep(text.c_str());
            if ((!ep.isV4() && !ep.isV6()) || !ep.port()) throw std::runtime_error("Invalid endpoint");
            if (std::find(r.stableEndpoints.begin(),r.stableEndpoints.end(),ep) == r.stableEndpoints.end()) r.stableEndpoints.push_back(ep);
        }
        roots.push_back(r);
    }
    return roots;
}
static ECC::Pair key(const std::string& p) {
    auto s=read(p);
    if (s.size()!=ZT_ECC_PUBLIC_KEY_SET_LEN+ZT_ECC_PRIVATE_KEY_SET_LEN) throw std::runtime_error("Invalid key: "+p);
    ECC::Pair k;
    memcpy(k.pub.data,s.data(),ZT_ECC_PUBLIC_KEY_SET_LEN);
    memcpy(k.priv.data,s.data()+ZT_ECC_PUBLIC_KEY_SET_LEN,ZT_ECC_PRIVATE_KEY_SET_LEN);
    return k;
}
static void save(const World& w,const std::string& p) {
    Buffer<ZT_WORLD_MAX_SERIALIZED_LENGTH> b; w.serialize(b,false);
    World check;
    if (check.deserialize(b,0)!=b.size() || check!=w) throw std::runtime_error("Serialization failed");
    write(p,std::string((const char*)b.data(),b.size()));
}
int main(int argc,char** argv) {
    try {
        std::string cmd=argc>1?argv[1]:"-j";
        if (cmd=="--help" || cmd=="-h") {
            puts("mkworld [-j|-b]\n  inspect PLANET\n  verify OLD NEW\n  validate ROOTS.json\n  build ROOTS.json OLD KEYS_DIR OUT\n  member PLANET IDENTITY.public"); return 0;
        }
        if (cmd=="inspect" && argc==3) { puts(describe(load(argv[2])).dump(2).c_str()); return 0; }
        if (cmd=="validate" && argc==3) { rootsFrom(json::parse(read(argv[2]))); return 0; }
        if (cmd=="member" && argc==4) {
            auto w=load(argv[2]); Identity id(read(argv[3]).c_str());
            rootsFrom(describe(w));
            for (const auto& r:w.roots()) if(r.identity==id) return 0;
            throw std::runtime_error("Local identity absent from planet");
        }
        if (cmd=="verify" && argc==4) {
            auto old=load(argv[2]); auto next=load(argv[3]);
            rootsFrom(describe(next));
            if (old==next || old.shouldBeReplacedBy(next)) return 0;
            throw std::runtime_error("Update rejected: signature, ID or timestamp mismatch");
        }
        if (cmd=="build" && argc==6) {
            auto roots=rootsFrom(json::parse(read(argv[2]))); auto old=load(argv[3]);
            // Retain every original root and its endpoints during initial expansion.
            if (old.roots().size()==1 && roots.size()>1) {
                const auto& original=old.roots()[0];
                auto it=std::find_if(roots.begin(),roots.end(),[&](const World::Root& r){return r.identity==original.identity;});
                if(it==roots.end()) throw std::runtime_error("Expansion must retain original root");
                for(const auto& ep:original.stableEndpoints)
                    if(std::find(it->stableEndpoints.begin(),it->stableEndpoints.end(),ep)==it->stableEndpoints.end())
                        throw std::runtime_error("Expansion must retain original endpoints");
            }
            if(roots==old.roots()) { save(old,argv[5]); return 0; }
            // Reuse an already prepared candidate, never advance timestamps on retries.
            std::string existing;
            if(OSUtils::readFile(argv[5],existing)) {
                auto candidate=load(argv[5]);
                if(candidate.roots()==roots && old.shouldBeReplacedBy(candidate)) return 0;
            }
            for(const char* name:{"current.c25519","previous.c25519"}) {
                std::string p=std::string(argv[4])+"/"+name, bytes;
                if(!OSUtils::readFile(p.c_str(),bytes)) continue;
                auto k=key(p);
                if(memcmp(k.pub.data,old.updatesMustBeSignedBy().data,ZT_ECC_PUBLIC_KEY_SET_LEN)) continue;
                if(old.timestamp()==UINT64_MAX) throw std::runtime_error("Timestamp overflow");
                auto next=World::make(World::TYPE_PLANET,old.id(),std::max((uint64_t)OSUtils::now(),old.timestamp()+1),old.updatesMustBeSignedBy(),roots,k);
                if(!old.shouldBeReplacedBy(next)) throw std::runtime_error("Signing key verification failed");
                save(next,argv[5]); return 0;
            }
            throw std::runtime_error("Missing matching signing key; restore backup, do not regenerate keys");
        }
        if((cmd=="-b" || cmd=="--bin2json") && argc==2) {
            auto s=describe(load("world.bin")).dump(4); write("config.json",s); puts(s.c_str()); return 0;
        }
        if((cmd=="-j" || cmd=="--json2bin") && argc<=2) {
            auto roots=rootsFrom(json::parse(read("moon.json")));
            std::string p,c;
            bool hp=OSUtils::readFile("previous.c25519",p), hc=OSUtils::readFile("current.c25519",c);
            if(!hp && !hc) {
                auto k=ECC::generate(); p.assign((const char*)k.pub.data,ZT_ECC_PUBLIC_KEY_SET_LEN);
                p.append((const char*)k.priv.data,ZT_ECC_PRIVATE_KEY_SET_LEN);
                write("previous.c25519",p); write("current.c25519",p);
                OSUtils::lockDownFile("previous.c25519",false); OSUtils::lockDownFile("current.c25519",false);
            } else if(!hp || !hc) throw std::runtime_error("Incomplete signing keys");
            save(World::make(World::TYPE_PLANET,ZT_WORLD_ID_EARTH,OSUtils::now(),key("current.c25519").pub,roots,key("previous.c25519")),"world.bin");
            return 0;
        }
        throw std::runtime_error("Invalid arguments; see --help");
    } catch(const std::exception& e) { fprintf(stderr,"mkworld: %s\n",e.what()); }
      catch(...) { fprintf(stderr,"mkworld: invalid binary/configuration\n"); }
    return 1;
}
