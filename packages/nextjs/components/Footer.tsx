import React from "react";
import { useTargetNetwork } from "~~/hooks/scaffold-stark/useTargetNetwork";
import { useGlobalState } from "~~/services/store/store";
import { devnet } from "@starknet-react/chains";

/**
 * Site footer
 */
export const Footer = () => {
  return (
    <div className="min-h-0 py-5 px-6  mb-6 lg:mb-0 bg-[#0F151A] flex justify-center mt-8">
      <span>
        THE MARQUIS. © 2024. All rights reserved. By using out website you
        consent to all cookies in accordance with out Terms and Privcy Policy
      </span>
    </div>
  );
};
